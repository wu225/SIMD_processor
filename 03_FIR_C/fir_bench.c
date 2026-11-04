#include <stdio.h>
#include "fir.h"

typedef unsigned long long ticks;
typedef struct {
    ticks total, minimum, maximum;
} statistics;

static int source[FIR_SAMPLES];
static int history_banks[2][FIR_TAPS - 1];
static int *history = history_banks[0];
static int *next_history = history_banks[1];
static int packed_next_history[FIR_TAPS - 1];
static int scalar_state[FIR_STATE_COUNT];
static unsigned packed_state[FIR_PACKED_CAPACITY];
static int h_reverse[FIR_TAPS];
static unsigned packed_h[FIR_TAPS];
static int scalar_out[FIR_SAMPLES];
static int packed_out[FIR_SAMPLES];
static int scratch_out[FIR_SAMPLES];
/* Visible in the debugger; consumed after measurement to preserve stores. */
volatile unsigned fir_result_checksum;
ticks fir_cycles[2][3][FIR_FRAMES][4];
static const int widths[3] = {8, 16, 32};
static const char *regions[4] = {
    "scalar_kernel", "mulp_kernel", "scalar_frame", "mulp_frame"
};

#ifdef FIR_HOST
#define CYCLE_NOW() 0ULL
#if defined(__GNUC__) || defined(__clang__)
#define BARRIER() __asm__ __volatile__("" : : : "memory")
#else
#define BARRIER() ((void)0)
#endif
#else
/* Built-ins are supplied by the processor's Chess compiler environment,
 * exactly as in the existing Dhrystone/CoreMark examples.
 */
#define CYCLE_NOW() chess_cycle_count()
#if defined(__clang__)
#define BARRIER() __asm__ __volatile__("/**/" : : : "memory")
#else
#define BARRIER() chess_separator_scheduler()
#endif
#endif

#define MEASURE(result, statements) do { \
    ticks begin_tick, end_tick; \
    BARRIER(); \
    begin_tick = CYCLE_NOW(); \
    BARRIER(); \
    statements; \
    BARRIER(); \
    end_tick = CYCLE_NOW(); \
    BARRIER(); \
    (result) = end_tick - begin_tick; \
} while (0)

static unsigned next_random(unsigned *state)
{
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

/* Independent, portable signed conversion for golden checks only. */
static int signed_word(unsigned raw)
{
    return raw <= 2147483647u ? (int)raw : -1 - (int)(~raw);
}

static int floor_shift(int value, int shift)
{
    int divisor = 1 << shift;
    return value >= 0 ? value / divisor : -1 - (-(value + 1)) / divisor;
}

static void set_coefficients(int mode, int asymmetric)
{
    int k, g, lane;
    int width = widths[mode];
    int lanes = 32 / width;
    unsigned mask = width == 8 ? 255u : (width == 16 ? 65535u : ~0u);
    for (k = 0; k < FIR_TAPS; ++k) {
        /* Non-symmetric full-length coefficients catch reversal errors. */
        int tap = FIR_TAPS - 1 - k;
        h_reverse[k] = asymmetric ? (tap % 7) - 3 : fir_coeff_fixture[mode][tap];
    }
    for (g = 0; g < FIR_TAPS / lanes; ++g) {
        unsigned word = 0;
        for (lane = 0; lane < lanes; ++lane)
            word |= ((unsigned)h_reverse[g * lanes + lane] & mask) << (lane * width);
        packed_h[g] = word;
    }
}

static void reset_history(void)
{
    int k;
    for (k = 0; k < FIR_TAPS - 1; ++k)
        history[k] = 0;
}

static void advance_history(void)
{
    int k;
    /* Correct even when FIR_SAMPLES < FIR_TAPS-1. */
    for (k = 0; k < FIR_TAPS - 1; ++k)
        history[k] = scalar_state[FIR_SAMPLES + k];
}

static FIR_NOINLINE void run_packed(int mode, int *out)
{
    if (mode == 0)
        fir_p8(packed_state, packed_h, out);
    else if (mode == 1)
        fir_p16(packed_state, packed_h, out);
    else
        fir_p32(packed_state, packed_h, out);
}

static int compare_outputs(const int *expected, const int *actual,
                           const char *name, int width, int frame)
{
    int n;
    for (n = 0; n < FIR_SAMPLES; ++n) {
        if (expected[n] != actual[n]) {
            printf("FAIL %s W=%d frame=%d n=%d expected=%d actual=%d\n",
                   name, width, frame, n, expected[n], actual[n]);
            return 1;
        }
    }
    return 0;
}

/* Direct causal FIR, using original coefficient order and full 64-bit MAC.
 * Does not share packed-window indexing or lane truncation with kernels.
 * All of this validation is outside measured intervals.
 */
static int check_reference(int mode, int asymmetric, const int *actual)
{
    int n, k;
    int shift = mode == 0 ? 12 : (mode == 1 ? 8 : 0);
    for (n = 0; n < FIR_SAMPLES; ++n) {
        long long acc = 0;
        for (k = 0; k < FIR_TAPS; ++k) {
            int index = n - k;
            int x = index >= 0 ? floor_shift(source[index], shift)
                               : history[FIR_TAPS - 1 + index];
            int h = asymmetric ? (k % 7) - 3 : fir_coeff_fixture[mode][k];
            long long product = (long long)x * h;
            long long limit = 1LL << (widths[mode] - 1);
            if (product < -limit || product >= limit) {
                printf("FAIL product overflow W=%d n=%d k=%d\n", widths[mode], n, k);
                return 1;
            }
            acc += product;
            if (acc < -2147483647LL - 1LL || acc > 2147483647LL) {
                printf("FAIL accumulator overflow W=%d n=%d k=%d\n", widths[mode], n, k);
                return 1;
            }
        }
        if (acc != actual[n]) {
            printf("FAIL causal reference W=%d n=%d expected=%lld actual=%d\n",
                   widths[mode], n, acc, actual[n]);
            return 1;
        }
    }
    return 0;
}

static unsigned checksum(const int *out)
{
    int n;
    unsigned hash = 2166136261u;
    for (n = 0; n < FIR_SAMPLES; ++n)
        hash = (hash ^ (unsigned)out[n]) * 16777619u;
    fir_result_checksum = hash;
    return hash;
}

static unsigned golden_pmul(unsigned a, unsigned b, int width)
{
    int lane;
    unsigned result = 0;
    unsigned long long mask = width == 32 ? 4294967295ULL : (1ULL << width) - 1ULL;
    for (lane = 0; lane < 32 / width; ++lane) {
        int shift = lane * width;
        unsigned long long x = (a >> shift) & mask;
        unsigned long long y = (b >> shift) & mask;
        result |= (unsigned)((x * y) & mask) << shift;
    }
    return result;
}

static int test_ordinary_multiply(void)
{
    /* Fixed expected bits, calculated offline. This test does not trust the
     * ordinary multiplier to produce its own reference value. */
    static const unsigned cases[][6] = {
        /* a, b, mul low, mulh (SS), mulhsu (SU), mulhu (UU) */
        {0x00000000u, 0x00000001u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
        {0x00000001u, 0x00000001u, 0x00000001u, 0x00000000u, 0x00000000u, 0x00000000u},
        {0x00000002u, 0x00000003u, 0x00000006u, 0x00000000u, 0x00000000u, 0x00000000u},
        {0x12345678u, 0x00000010u, 0x23456780u, 0x00000001u, 0x00000001u, 0x00000001u},
        {0xFFFFFFFFu, 0x00000002u, 0xFFFFFFFEu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0x00000001u},
        {0xFFFFFFFFu, 0xFFFFFFFFu, 0x00000001u, 0x00000000u, 0xFFFFFFFFu, 0xFFFFFFFEu},
        {0x80000000u, 0x00000002u, 0x00000000u, 0xFFFFFFFFu, 0xFFFFFFFFu, 0x00000001u},
        {0x80000000u, 0x80000000u, 0x00000000u, 0x40000000u, 0xC0000000u, 0x40000000u},
        {0x7FFFFFFFu, 0x7FFFFFFFu, 0x00000001u, 0x3FFFFFFFu, 0x3FFFFFFFu, 0x3FFFFFFFu},
        {0x80000000u, 0xFFFFFFFFu, 0x80000000u, 0x00000000u, 0x80000000u, 0x7FFFFFFFu},
        {0x7FFFFFFFu, 0xFFFFFFFFu, 0x80000001u, 0xFFFFFFFFu, 0x7FFFFFFEu, 0x7FFFFFFEu},
        {0xDEADBEEFu, 0x10203040u, 0x0D1C8BC0u, 0xFDE6AB5Fu, 0xFDE6AB5Fu, 0x0E06DB9Fu}
    };
    static const char *names[] = {"mul", "mulh", "mulhsu", "mulhu"};
    int t, op;
    for (t = 0; t < 12; ++t) {
        unsigned a = cases[t][0], b = cases[t][1];
        unsigned actual[4];
        actual[0] = fir_probe_mul(a, b);
        actual[1] = fir_probe_mulh_ss(signed_word(a), signed_word(b));
        actual[2] = fir_probe_mulh_su(signed_word(a), b);
        actual[3] = fir_probe_mulh_uu(a, b);
        for (op = 0; op < 4; ++op) {
            if (actual[op] != cases[t][op + 2]) {
                printf("FAIL ordinary %s a=%08X b=%08X expected=%08X actual=%08X\n",
                       names[op], a, b, cases[t][op + 2], actual[op]);
                printf("Check lib/trv32p5.p mul_hw; rebuild the processor model, runtime libraries and CA ISS before compiling fir.prx.\n");
                return 1;
            }
        }
    }
    printf("PASS ordinary multiply tests: 48 fixed-reference cases\n");
    return 0;
}

static int test_instructions(void)
{
    static const unsigned edge[] = {
        0u, 1u, 0xffffffffu, 0x80808080u, 0x7f7f7f7fu,
        0x80008000u, 0x7fff7fffu, 0x80000000u, 0x7fffffffu,
        0x01020408u, 0xff807f10u, 0xdeadbeefu
    };
    unsigned rng = 20261003u;
    int mode, t;
    for (mode = 0; mode < 3; ++mode) {
        /* Runtime operands; prevents a constant-folded intrinsic test. */
        for (t = 0; t < 272; ++t) {
            unsigned a = t < 144 ? edge[t / 12] : next_random(&rng);
            unsigned b = t < 144 ? edge[t % 12] : next_random(&rng);
            unsigned expected = golden_pmul(a, b, widths[mode]);
            unsigned actual = mode == 0 ? mulp8(a, b)
                            : mode == 1 ? mulp16(a, b)
                            : (unsigned)mulp32(signed_word(a), signed_word(b));
            if (actual != expected) {
                printf("FAIL mulp%d a=%08X b=%08X expected=%08X actual=%08X\n",
                       widths[mode], a, b, expected, actual);
                return 1;
            }
        }
    }
    printf("PASS instruction tests: 816 cases\n");
    return 0;
}

static int test_fir(void)
{
    int mode, kind, frame, n;
    for (mode = 0; mode < 3; ++mode) {
        for (kind = 0; kind < 5; ++kind) {
            int asymmetric = kind == 4;
            reset_history();
            set_coefficients(mode, asymmetric);
            for (frame = 0; frame < 2; ++frame) {
                for (n = 0; n < FIR_SAMPLES; ++n) {
                    if (kind == 0) source[n] = 0;
                    else if (kind == 1) source[n] = frame == 0 && n == 0 ? 24576 : 0;
                    else if (kind == 2) source[n] = (n & 1) ? -32768 : 32768;
                    else if (kind == 3) {
                        static const int edge[] = {-32768,-2049,-2048,-1,0,1,2047,2048,32767,32768};
                        source[n] = edge[(frame * FIR_SAMPLES + n) % 10];
                    } else {
                        /* Safe full products for every width in this test. */
                        source[n] = (((frame * FIR_SAMPLES + n) * 5) % 17 - 8) * 4096;
                    }
                }
                fir_prepare_scalar(source, history, widths[mode], scalar_state);
                fir_prepare_packed(source, history, widths[mode], packed_state);
                fir_scalar(scalar_state, h_reverse, scalar_out);
                run_packed(mode, packed_out);
                if (compare_outputs(scalar_out, packed_out, "functional", widths[mode], frame)
                    || check_reference(mode, asymmetric, packed_out)) return 1;
                advance_history();
            }
        }
    }
    printf("PASS FIR tests: zero, impulse, alternating full input, shift edges, asymmetric taps; 2 frames each\n");
    return 0;
}

static void add_stat(statistics *s, ticks value, int frame)
{
    s->total += value;
    if (frame == 0 || value < s->minimum) s->minimum = value;
    if (frame == 0 || value > s->maximum) s->maximum = value;
}

static int benchmark(void)
{
    int input, mode, frame, n, r;
    ticks overhead;
    MEASURE(overhead, (void)0);
    printf("timer_pair_cycles=%llu (raw measurements; no overhead subtraction)\n", overhead);
    printf("ROW,input,width,frame,scalar_kernel,mulp_kernel,scalar_frame,mulp_frame,checksum\n");
    for (input = 0; input < 2; ++input) {
        for (mode = 0; mode < 3; ++mode) {
            unsigned rng = 20261003u;
            statistics stats[4];
            for (r = 0; r < 4; ++r) {
                stats[r].total = stats[r].minimum = stats[r].maximum = 0;
            }
            set_coefficients(mode, 0);
            reset_history();
            for (frame = 0; frame < FIR_FRAMES; ++frame) {
                ticks *c = fir_cycles[input][mode][frame];
                unsigned hash;
                for (n = 0; n < FIR_SAMPLES; ++n) {
                    /* Same Q15 source stream for all three modes.
                     * Random amplitude <=0.8; tone period is exactly 100.
                     */
                    source[n] = input == 0
                        ? (((int)(next_random(&rng) >> 16) - 32768) * 4) / 5
                        : fir_tone_q15[(frame * FIR_SAMPLES + n) % FIR_TONE_PERIOD];
                }
                /* Kernel-only inputs are prepared outside the first two timers. */
                fir_prepare_scalar(source, history, widths[mode], scalar_state);
                fir_prepare_packed(source, history, widths[mode], packed_state);
                MEASURE(c[0], fir_scalar(scalar_state, h_reverse, scalar_out));
                MEASURE(c[1], run_packed(mode, packed_out));
                if (compare_outputs(scalar_out, packed_out, "kernel", widths[mode], frame)) return 1;
                MEASURE(c[2], {
                    fir_prepare_scalar(source, history, widths[mode], scalar_state);
                    fir_scalar(scalar_state, h_reverse, scratch_out);
                    fir_save_scalar_history(scalar_state, next_history);
                });
                if (compare_outputs(scalar_out, scratch_out, "scalar complete", widths[mode], frame)) return 1;
                MEASURE(c[3], {
                    fir_prepare_packed(source, history, widths[mode], packed_state);
                    run_packed(mode, scratch_out);
                    fir_save_packed_history(packed_state, widths[mode], packed_next_history);
                });
                if (compare_outputs(scalar_out, scratch_out, "mulp complete", widths[mode], frame)
                    || check_reference(mode, 0, scratch_out)) return 1;
                hash = checksum(scratch_out);
                printf("ROW,%s,%d,%d,%llu,%llu,%llu,%llu,%08X\n",
                       input == 0 ? "random" : "two_tone", widths[mode], frame,
                       c[0], c[1], c[2], c[3], hash);
#if FIR_DUMP
                for (n = 0; n < FIR_SAMPLES; ++n)
                    printf("DATA,%s,%d,%d,%d,%d,%d\n", input == 0 ? "random" : "two_tone",
                           widths[mode], frame, n, source[n], scratch_out[n]);
#endif
                for (r = 0; r < 4; ++r) add_stat(&stats[r], c[r], frame);
                for (n = 0; n < FIR_TAPS - 1; ++n) {
                    if (next_history[n] != packed_next_history[n]) {
                        printf("FAIL outgoing history W=%d frame=%d k=%d\n", widths[mode], frame, n);
                        return 1;
                    }
                }
                /* Outgoing history saving is timed in each frame path.
                 * Pointer swap is only harness bookkeeping. */
                {
                    int *old_history = history;
                    history = next_history;
                    next_history = old_history;
                }
            }
            for (r = 0; r < 4; ++r) {
                printf("SUMMARY,%s,%d,%s,total=%llu,min=%llu,max=%llu,frames=%d,samples_per_frame=%d\n",
                       input == 0 ? "random" : "two_tone", widths[mode], regions[r],
                       stats[r].total, stats[r].minimum, stats[r].maximum, FIR_FRAMES, FIR_SAMPLES);
            }
        }
    }
    return 0;
}

int main(void)
{
    int mode;
    printf("FIR C implementation=%s\n", FIR_IMPLEMENTATION);
#ifdef FIR_HOST
    printf("HOST FUNCTIONAL CHECK: all cycle fields are 0; use trv32p5_ca for cycle measurements.\n");
#else
    printf("ASIP FIR cycle benchmark: use the cycle-accurate trv32p5_ca ISS.\n");
#endif
    printf("FIR taps=%d samples/frame=%d frames/input=%d; SR=off; deterministic input truncation; raw accumulator output\n",
           FIR_TAPS, FIR_SAMPLES, FIR_FRAMES);
    for (mode = 0; mode < 3; ++mode)
        printf("W=%d product_bound=%d acc_bound=%d scalar_MUL/frame=%d mulp/frame=%d\n",
               widths[mode], fir_product_bound[mode], fir_acc_bound[mode],
               FIR_SAMPLES * FIR_TAPS, FIR_SAMPLES * (FIR_TAPS / (32 / widths[mode])));
    if (test_ordinary_multiply() || test_instructions() || test_fir() || benchmark()) return 1;
    printf("PASS all FIR comparisons; checksum=%08X\n", fir_result_checksum);
    return 0;
}
