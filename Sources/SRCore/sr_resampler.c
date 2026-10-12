// sr_resampler.c — drift-compensating variable-ratio resampler (4-point 3rd-order Hermite).
//
// Scratch layout per channel: [h0 h1 h2 | x0 x1 ... x(m-1)] where h0..h2 are the last three
// input samples kept from the previous call (so the interpolation kernel is continuous
// across calls) and x are frames peeked from the ring. The read position `pos` is expressed
// in scratch coordinates and kept in [1, 2) between calls: output sample k uses
// s[i-1], s[i], s[i+1], s[i+2] with i = floor(pos), mu = pos - i.
//
// Control loop: fill error e = (fill_smoothed - target) / target. With τ0 = target/srcRate
// the plant is  τ0·de/dt = d - u  (d = relative clock drift, u = ratio correction), so a
// PI controller u = Kp·e + Ki·∫e dt with Kp = 2·τ0·p, Ki = τ0·p² gives a critically damped
// loop with both poles at -p. p = 0.5 rad/s (settles in ~10 s, far below audibility).

#include "sr_internal.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define DRS_CHUNK        512u     /* output frames per internal block */
#define DRS_HIST         3u
#define DRS_MAX_DEV      0.01     /* ratio clamp: +/- 1 % around nominal */
#define DRS_POLE         0.5      /* rad/s, closed-loop poles */
#define DRS_SMOOTH_TAU   0.25     /* s, fill-level smoothing */

struct SRDriftResampler {
    uint32_t channels;
    uint32_t target;
    double   srcRate, dstRate, nominal;
    double   kp, ki;
    double   integ;
    double   smoothFill;
    double   pos;
    bool     waiting;
    uint32_t maxIn;          /* max ring frames peeked per block */
    uint32_t stride;         /* floats per channel in scratch */
    float   *scratch;        /* channels * stride */
    float  **peekPlanes;     /* scratch + c*stride + DRS_HIST */
    _Atomic uint64_t ratioBits;
    _Atomic uint64_t underruns;
};

static inline void store_ratio(SRDriftResampler *r, double ratio) {
    union { double d; uint64_t u; } x; x.d = ratio;
    atomic_store_explicit(&r->ratioBits, x.u, memory_order_relaxed);
}

static inline double load_ratio(const SRDriftResampler *r) {
    union { double d; uint64_t u; } x;
    x.u = atomic_load_explicit(&((SRDriftResampler *)r)->ratioBits, memory_order_relaxed);
    return x.d;
}

SRDriftResampler *sr_drs_create(uint32_t channels, double srcRate, double dstRate,
                                uint32_t targetFillFrames) {
    if (channels == 0 || !(srcRate > 0) || !(dstRate > 0)) return NULL;
    SRDriftResampler *r = (SRDriftResampler *)calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->channels = channels;
    r->srcRate = srcRate;
    r->dstRate = dstRate;
    r->nominal = srcRate / dstRate;
    r->target = targetFillFrames ? targetFillFrames : 1;
    double tau0 = (double)r->target / srcRate;
    r->kp = 2.0 * tau0 * DRS_POLE;
    r->ki = tau0 * DRS_POLE * DRS_POLE;
    r->maxIn = (uint32_t)ceil(DRS_CHUNK * r->nominal * (1.0 + 2 * DRS_MAX_DEV)) + 8;
    r->stride = r->maxIn + DRS_HIST + 4;
    r->scratch = (float *)calloc((size_t)channels * r->stride, sizeof(float));
    r->peekPlanes = (float **)calloc(channels, sizeof(float *));
    if (!r->scratch || !r->peekPlanes) { sr_drs_destroy(r); return NULL; }
    for (uint32_t c = 0; c < channels; ++c)
        r->peekPlanes[c] = r->scratch + (size_t)c * r->stride + DRS_HIST;
    atomic_init(&r->underruns, 0);
    atomic_init(&r->ratioBits, 0);
    sr_drs_reset(r);
    return r;
}

void sr_drs_destroy(SRDriftResampler *r) {
    if (!r) return;
    free(r->scratch);
    free(r->peekPlanes);
    free(r);
}

static void clear_history(SRDriftResampler *r) {
    for (uint32_t c = 0; c < r->channels; ++c) {
        float *s = r->scratch + (size_t)c * r->stride;
        s[0] = s[1] = s[2] = 0.0f;
    }
    r->pos = 1.0;
}

/* Does not reset the underrun counter (it is a lifetime statistic). */
void sr_drs_reset(SRDriftResampler *r) {
    clear_history(r);
    r->integ = 0;
    r->smoothFill = r->target;
    r->waiting = true;
    store_ratio(r, r->nominal);
}

double sr_drs_ratio(const SRDriftResampler *r) { return load_ratio(r); }

uint64_t sr_drs_underruns(const SRDriftResampler *r) {
    return atomic_load_explicit(&((SRDriftResampler *)r)->underruns, memory_order_relaxed);
}

static inline float hermite(const float *s, float mu) {
    float xm1 = s[-1], x0 = s[0], x1 = s[1], x2 = s[2];
    float c1 = 0.5f * (x1 - xm1);
    float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * mu + c2) * mu + c1) * mu + x0;
}

static void zero_out(float *const *out, uint32_t channels, uint32_t from, uint32_t to) {
    if (to <= from) return;
    for (uint32_t c = 0; c < channels; ++c)
        if (out[c]) memset(out[c] + from, 0, (to - from) * sizeof(float));
}

uint32_t sr_drs_pull(SRDriftResampler *r, SRRing *ring, float *const *out, uint32_t frames) {
    if (frames == 0) return 0;
    if (!ring) { zero_out(out, r->channels, 0, frames); return 0; }

    uint32_t avail = sr_ring_readable(ring);

    /* Large overflow (producer ran far ahead, e.g. after a stall): jump back to target. */
    if (avail > 3u * r->target) {
        sr_ring_skip(ring, avail - r->target);
        avail = r->target;
        r->smoothFill = r->target;
    }

    if (r->waiting) {
        if (avail < r->target) { zero_out(out, r->channels, 0, frames); return 0; }
        r->waiting = false;
        clear_history(r);
        r->smoothFill = avail;
    }

    /* PI controller on the smoothed fill level. */
    double dt = (double)frames / r->dstRate;
    double alpha = 1.0 - exp(-dt / DRS_SMOOTH_TAU);
    r->smoothFill += alpha * ((double)avail - r->smoothFill);
    double e = (r->smoothFill - (double)r->target) / (double)r->target;
    r->integ += e * dt;
    double imax = DRS_MAX_DEV / r->ki;
    if (r->integ > imax) r->integ = imax;
    if (r->integ < -imax) r->integ = -imax;
    double u = r->kp * e + r->ki * r->integ;
    if (u > DRS_MAX_DEV) u = DRS_MAX_DEV;
    if (u < -DRS_MAX_DEV) u = -DRS_MAX_DEV;
    double ratio = r->nominal * (1.0 + u);
    store_ratio(r, ratio);

    uint32_t produced = 0;
    while (produced < frames) {
        uint32_t n = frames - produced;
        if (n > DRS_CHUNK) n = DRS_CHUNK;

        uint32_t want = (uint32_t)(r->pos + (double)n * ratio) + 2u;
        if (want > r->maxIn) want = r->maxIn;
        uint32_t m = sr_ring_peek_n(ring, r->peekPlanes, r->channels, want);

        /* Render every channel with the same position sequence. */
        uint32_t k = 0;
        double p = r->pos;
        for (uint32_t c = 0; c < r->channels; ++c) {
            const float *s = r->scratch + (size_t)c * r->stride;
            float *o = out[c] ? out[c] + produced : NULL;
            p = r->pos;
            for (k = 0; k < n; ++k) {
                uint32_t i = (uint32_t)p;
                if (i > m) break;
                if (o) o[k] = hermite(s + i, (float)(p - (double)i));
                p += ratio;
            }
        }

        uint32_t consumed = (uint32_t)p - 1u;
        /* Never consume more than was peeked; the remainder stays in the ring and `pos`
         * keeps pointing past the history, which remains consistent for the next block. */
        if (consumed > m) consumed = m;
        for (uint32_t c = 0; c < r->channels; ++c) {
            float *s = r->scratch + (size_t)c * r->stride;
            float h0 = s[consumed], h1 = s[consumed + 1], h2 = s[consumed + 2];
            s[0] = h0; s[1] = h1; s[2] = h2;
        }
        sr_ring_skip(ring, consumed);
        r->pos = p - (double)consumed;
        produced += k;

        if (k < n) {
            /* Underrun: silence for the rest, then wait until the ring refills to target. */
            zero_out(out, r->channels, produced, frames);
            atomic_fetch_add_explicit(&r->underruns, 1, memory_order_relaxed);
            r->waiting = true;
            clear_history(r);
            break;
        }
    }
    return produced;
}
