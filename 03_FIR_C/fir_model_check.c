#include "fir.h"

/* Keep these functions separate from the fixture tables and the reference.
 * On target their operands are runtime values, so ordinary mul/mulh/mulhsu/
 * mulhu are actually exercised rather than folded into constants.
 */
unsigned fir_probe_mul(unsigned a, unsigned b)
{
    return a * b;
}

unsigned fir_probe_mulh_ss(int a, int b)
{
#ifdef FIR_HOST
    long long product = (long long)a * b;
    return (unsigned)((unsigned long long)product >> 32);
#else
    return (unsigned)mulh(a, b);
#endif
}

unsigned fir_probe_mulh_su(int a, unsigned b)
{
#ifdef FIR_HOST
    long long product = (long long)a * (long long)b;
    return (unsigned)((unsigned long long)product >> 32);
#else
    return (unsigned)mulh(a, b);
#endif
}

unsigned fir_probe_mulh_uu(unsigned a, unsigned b)
{
#ifdef FIR_HOST
    return (unsigned)(((unsigned long long)a * b) >> 32);
#else
    return mulh(a, b);
#endif
}
