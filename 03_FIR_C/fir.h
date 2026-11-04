#ifndef FIR_MULP_H
#define FIR_MULP_H

#include <limits.h>
#include "fir_fixture.h"

#ifndef FIR_SAMPLES
#define FIR_SAMPLES 1024
#endif
#ifndef FIR_FRAMES
#define FIR_FRAMES 10
#endif
#ifndef FIR_DUMP
#define FIR_DUMP 0
#endif
#if FIR_SAMPLES < 1 || FIR_FRAMES < 1
#error "FIR_SAMPLES and FIR_FRAMES must be positive"
#endif
#if FIR_TAPS < 4 || (FIR_TAPS % 4) != 0
#error "FIR_TAPS must be at least four and divisible by four"
#endif
#define FIR_IMPLEMENTATION "optimized_v1"
#if CHAR_BIT != 8 || INT_MAX != 2147483647 || SHRT_MAX != 32767
#error "This benchmark needs 8-bit bytes, 16-bit short and 32-bit int"
#endif

#define FIR_STATE_COUNT (FIR_SAMPLES + FIR_TAPS - 1)
/* Enough for MODE32 as well as rounded-up MODE8/16, plus a zero sentinel. */
#define FIR_PACKED_CAPACITY (FIR_STATE_COUNT + 1)

#if defined(__clang__) || defined(__GNUC__)
#define FIR_NOINLINE __attribute__((noinline))
#else
#define FIR_NOINLINE
#endif

/* Host emulation is ONLY a functional check; it never reports CPU cycles. */
#ifdef FIR_HOST
static inline unsigned mulp8(unsigned a, unsigned b)
{
    unsigned r = 0, lane;
    for (lane = 0; lane < 4; ++lane) {
        unsigned s = lane * 8;
        r |= ((((a >> s) & 255u) * ((b >> s) & 255u)) & 255u) << s;
    }
    return r;
}
static inline unsigned mulp16(unsigned a, unsigned b)
{
    return (((a & 65535u) * (b & 65535u)) & 65535u)
         | ((((a >> 16) * (b >> 16)) & 65535u) << 16);
}
static inline int mulp32(int a, int b)
{
    unsigned u = (unsigned)a * (unsigned)b;
    return u <= 2147483647u ? (int)u : -1 - (int)(~u);
}
#endif

/* Coefficients are supplied at runtime to each kernel. No constant tap removal. */
FIR_NOINLINE void fir_scalar(const int *state, const int *h_reverse, int *out);
FIR_NOINLINE void fir_p8(const unsigned *state, const unsigned *h, int *out);
FIR_NOINLINE void fir_p16(const unsigned *state, const unsigned *h, int *out);
FIR_NOINLINE void fir_p32(const unsigned *state, const unsigned *h, int *out);
FIR_NOINLINE void fir_prepare_scalar(const int *source, const int *history,
                                    int width, int *state);
FIR_NOINLINE void fir_prepare_packed(const int *source, const int *history,
                                    int width, unsigned *state);
FIR_NOINLINE void fir_save_scalar_history(const int *state, int *next_history);
FIR_NOINLINE void fir_save_packed_history(const unsigned *state, int width,
                                        int *next_history);
/* Separate translation unit: probe ordinary instructions with runtime operands. */
FIR_NOINLINE unsigned fir_probe_mul(unsigned a, unsigned b);
FIR_NOINLINE unsigned fir_probe_mulh_ss(int a, int b);
FIR_NOINLINE unsigned fir_probe_mulh_su(int a, unsigned b);
FIR_NOINLINE unsigned fir_probe_mulh_uu(unsigned a, unsigned b);

#endif
