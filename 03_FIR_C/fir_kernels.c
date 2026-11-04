#include "fir.h"

/* y[n] = sum(h[k] * x[n-k]); state starts with FIR_TAPS-1 old samples.
 * An increasing state window therefore uses reversed coefficients.
 * No output scaling: each output is a signed 32-bit raw accumulator.
 */
void fir_scalar(const int *state, const int *h_reverse, int *out)
{
    int n, k;
    for (n = 0; n < FIR_SAMPLES; ++n) {
        int acc = 0;
        for (k = 0; k < FIR_TAPS; ++k)
            acc += state[n + k] * h_reverse[k];
        out[n] = acc;
    }
}

void fir_p8(const unsigned *state, const unsigned *h, int *out)
{
    int n, g;
    for (n = 0; n < FIR_SAMPLES; ++n) {
        unsigned shift = ((unsigned)n & 3u) * 8u;
        const unsigned *x = state + ((unsigned)n >> 2);
        int acc = 0;
        /* Separate aligned case: never evaluate a shift by 32. */
        if (shift == 0) {
            for (g = 0; g < FIR_TAPS / 4; ++g) {
                unsigned p = mulp8(x[g], h[g]);
                /* Left shifts are unsigned; right shifts are signed sra.
                 * Avoid w08 casts: Noodle lowered them to stack sb/lb. */
                acc += (int)(p << 24) >> 24;
                acc += (int)(p << 16) >> 24;
                acc += (int)(p << 8) >> 24;
                acc += (int)p >> 24;
            }
        } else {
            unsigned previous = x[0];
            for (g = 0; g < FIR_TAPS / 4; ++g) {
                unsigned following = x[g + 1];
                unsigned a = (previous >> shift) | (following << (32u - shift));
                unsigned p = mulp8(a, h[g]);
                /* The next group reuses the word we just loaded. */
                previous = following;
                /* Every lane is sign-extended BEFORE scalar addition.
                 * A plain packed 32-bit add would carry across lanes.
                 */
                acc += (int)(p << 24) >> 24;
                acc += (int)(p << 16) >> 24;
                acc += (int)(p << 8) >> 24;
                acc += (int)p >> 24;
            }
        }
        out[n] = acc;
    }
}

void fir_p16(const unsigned *state, const unsigned *h, int *out)
{
    int n, g;
    for (n = 0; n < FIR_SAMPLES; ++n) {
        const unsigned *x = state + ((unsigned)n >> 1);
        int acc = 0;
        if (((unsigned)n & 1u) == 0) {
            for (g = 0; g < FIR_TAPS / 2; ++g) {
                unsigned p = mulp16(x[g], h[g]);
                acc += (int)(p << 16) >> 16;
                acc += (int)p >> 16;
            }
        } else {
            unsigned previous = x[0];
            for (g = 0; g < FIR_TAPS / 2; ++g) {
                unsigned following = x[g + 1];
                unsigned a = (previous >> 16) | (following << 16);
                unsigned p = mulp16(a, h[g]);
                previous = following;
                acc += (int)(p << 16) >> 16;
                acc += (int)p >> 16;
            }
        }
        out[n] = acc;
    }
}

void fir_p32(const unsigned *state, const unsigned *h, int *out)
{
    int n, k;
    for (n = 0; n < FIR_SAMPLES; ++n) {
        int acc = 0;
        for (k = 0; k < FIR_TAPS; ++k)
            acc += mulp32((int)state[n + k], (int)h[k]);
        out[n] = acc;
    }
}

void fir_prepare_scalar(const int *source, const int *history,
                        int width, int *state)
{
    int i;
    int shift = width == 8 ? 12 : (width == 16 ? 8 : 0);
    for (i = 0; i < FIR_TAPS - 1; ++i)
        state[i] = history[i];
    for (i = 0; i < FIR_SAMPLES; ++i)
        /* trv32p5 signed right shift is arithmetic (floor for negatives).
         * This deterministic truncation substitutes for deferred SR.
         */
        state[FIR_TAPS - 1 + i] = source[i] >> shift;
}

/* Only the low lane bits of a quantized value are needed when packing.
 * Arithmetic right shift of a negative sample gives the same low lane
 * bits as extracting its bit field. All packing left shifts are unsigned.
 * FIR_TAPS is divisible by four, so history ends with three bytes (p8)
 * or one halfword (p16); handle the history/source join exactly once.
 */
#define PACK8(a,b,c,d) (((unsigned)(a) & 255u) \
    | (((unsigned)(b) & 255u) << 8) \
    | (((unsigned)(c) & 255u) << 16) | ((unsigned)(d) << 24))
#define PACK16(a,b) (((unsigned)(a) & 65535u) | ((unsigned)(b) << 16))

static void prepare_p8(const int *source, const int *history, unsigned *state)
{
    int i, word;
    for (i = 0; i < FIR_TAPS - 4; i += 4)
        state[i >> 2] = PACK8(history[i], history[i + 1], history[i + 2], history[i + 3]);
    state[FIR_TAPS / 4 - 1] = PACK8(history[FIR_TAPS - 4], history[FIR_TAPS - 3],
                                    history[FIR_TAPS - 2], source[0] >> 12);
    word = FIR_TAPS / 4;
    for (i = 1; i + 3 < FIR_SAMPLES; i += 4)
        state[word++] = PACK8(source[i] >> 12, source[i + 1] >> 12,
                              source[i + 2] >> 12, source[i + 3] >> 12);
    if (i < FIR_SAMPLES) {
        unsigned tail = (unsigned)(source[i++] >> 12) & 255u;
        if (i < FIR_SAMPLES) {
            tail |= ((unsigned)(source[i++] >> 12) & 255u) << 8;
            if (i < FIR_SAMPLES)
                tail |= ((unsigned)(source[i] >> 12) & 255u) << 16;
        }
        state[word++] = tail;
    }
    state[word] = 0;
}

static void prepare_p16(const int *source, const int *history, unsigned *state)
{
    int i, word;
    for (i = 0; i < FIR_TAPS - 2; i += 2)
        state[i >> 1] = PACK16(history[i], history[i + 1]);
    state[FIR_TAPS / 2 - 1] = PACK16(history[FIR_TAPS - 2], source[0] >> 8);
    word = FIR_TAPS / 2;
    for (i = 1; i + 1 < FIR_SAMPLES; i += 2)
        state[word++] = PACK16(source[i] >> 8, source[i + 1] >> 8);
    if (i < FIR_SAMPLES)
        state[word++] = (unsigned)(source[i] >> 8) & 65535u;
    state[word] = 0;
}

static void prepare_p32(const int *source, const int *history, unsigned *state)
{
    int i;
    /* One lane: direct copy, with the same state layout as scalar FIR. */
    for (i = 0; i < FIR_TAPS - 1; ++i)
        state[i] = (unsigned)history[i];
    for (i = 0; i < FIR_SAMPLES; ++i)
        state[FIR_TAPS - 1 + i] = (unsigned)source[i];
    state[FIR_STATE_COUNT] = 0;
}

void fir_prepare_packed(const int *source, const int *history,
                        int width, unsigned *state)
{
    if (width == 8)
        prepare_p8(source, history, state);
    else if (width == 16)
        prepare_p16(source, history, state);
    else
        prepare_p32(source, history, state);
}

void fir_save_scalar_history(const int *state, int *next_history)
{
    int k;
    for (k = 0; k < FIR_TAPS - 1; ++k)
        next_history[k] = state[FIR_SAMPLES + k];
}

static void save_p8(const unsigned *state, int *next_history)
{
    int k = 0;
    int prefix = (4 - (FIR_SAMPLES & 3)) & 3;
    /* Consume up to three samples to reach a word boundary. */
    for (; k < prefix; ++k) {
        unsigned index = (unsigned)(FIR_SAMPLES + k);
        unsigned p = state[index >> 2] >> ((index & 3u) * 8u);
        next_history[k] = (int)(p << 24) >> 24;
    }
    for (; k + 3 < FIR_TAPS - 1; k += 4) {
        unsigned p = state[(FIR_SAMPLES + k) >> 2];
        next_history[k] = (int)(p << 24) >> 24;
        next_history[k + 1] = (int)(p << 16) >> 24;
        next_history[k + 2] = (int)(p << 8) >> 24;
        next_history[k + 3] = (int)p >> 24;
    }
    for (; k < FIR_TAPS - 1; ++k) {
        unsigned index = (unsigned)(FIR_SAMPLES + k);
        unsigned p = state[index >> 2] >> ((index & 3u) * 8u);
        next_history[k] = (int)(p << 24) >> 24;
    }
}

static void save_p16(const unsigned *state, int *next_history)
{
    int k = 0;
#if (FIR_SAMPLES & 1)
    next_history[0] = (int)state[FIR_SAMPLES >> 1] >> 16;
    k = 1;
#endif
    for (; k + 1 < FIR_TAPS - 1; k += 2) {
        unsigned p = state[(FIR_SAMPLES + k) >> 1];
        next_history[k] = (int)(p << 16) >> 16;
        next_history[k + 1] = (int)p >> 16;
    }
    if (k < FIR_TAPS - 1)
        next_history[k] = (int)(state[(FIR_SAMPLES + k) >> 1] << 16) >> 16;
}

static void save_p32(const unsigned *state, int *next_history)
{
    int k;
    for (k = 0; k < FIR_TAPS - 1; ++k)
        next_history[k] = (int)state[FIR_SAMPLES + k];
}

void fir_save_packed_history(const unsigned *state, int width, int *next_history)
{
    if (width == 8)
        save_p8(state, next_history);
    else if (width == 16)
        save_p16(state, next_history);
    else
        save_p32(state, next_history);
}
