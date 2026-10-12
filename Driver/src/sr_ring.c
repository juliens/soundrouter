// sr_ring.c — see sr_ring.h. Real-time safe.

#include "sr_ring.h"
#include "sr_shm.h"

#include <string.h>

void sr_ring_valid_range(int64_t writeFrame, int64_t start, uint32_t n,
                         uint32_t *first, uint32_t *count) {
    int64_t lo = start;
    int64_t hi = start + (int64_t)n;
    int64_t oldest = writeFrame - (int64_t)SR_RING_FRAMES;
    if (lo < oldest) lo = oldest;
    if (hi > writeFrame) hi = writeFrame;
    if (hi <= lo) { *first = 0; *count = 0; return; }
    *first = (uint32_t)(lo - start);
    *count = (uint32_t)(hi - lo);
}

static inline uint32_t ring_index(int64_t s) {
    return (uint32_t)((uint64_t)s & (uint64_t)SR_RING_MASK); /* two's complement: OK for s < 0 */
}

uint32_t sr_ring_read(const float *planes, uint32_t planeChannels, int64_t writeFrame,
                      int64_t start, uint32_t n,
                      float *out, uint32_t outChannels, int interleaved) {
    uint32_t first, count;
    if (!out || n == 0 || outChannels == 0) return 0;
    if (!planes || planeChannels == 0) {
        memset(out, 0, (size_t)n * outChannels * sizeof(float));
        return 0;
    }
    sr_ring_valid_range(writeFrame, start, n, &first, &count);
    uint32_t chs = planeChannels < outChannels ? planeChannels : outChannels;

    if (interleaved) {
        if (count < n) {
            /* zero only the invalid head / tail, and missing channels in the valid part */
            memset(out, 0, (size_t)first * outChannels * sizeof(float));
            memset(out + (size_t)(first + count) * outChannels, 0,
                   (size_t)(n - first - count) * outChannels * sizeof(float));
        }
        if (chs < outChannels)
            for (uint32_t k = first; k < first + count; ++k)
                memset(out + (size_t)k * outChannels + chs, 0, (size_t)(outChannels - chs) * sizeof(float));
        for (uint32_t ch = 0; ch < chs; ++ch) {
            const float *plane = planes + (size_t)ch * SR_RING_FRAMES;
            uint32_t idx = ring_index(start + first);
            float *o = out + (size_t)first * outChannels + ch;
            for (uint32_t k = 0; k < count; ++k) {
                *o = plane[idx];
                o += outChannels;
                idx = (idx + 1u) & SR_RING_MASK;
            }
        }
    } else {
        for (uint32_t ch = 0; ch < outChannels; ++ch) {
            float *o = out + (size_t)ch * n;
            if (ch >= chs || count == 0) { memset(o, 0, (size_t)n * sizeof(float)); continue; }
            const float *plane = planes + (size_t)ch * SR_RING_FRAMES;
            memset(o, 0, (size_t)first * sizeof(float));
            memset(o + first + count, 0, (size_t)(n - first - count) * sizeof(float));
            uint32_t idx = ring_index(start + first);
            uint32_t seg1 = SR_RING_FRAMES - idx;
            if (seg1 > count) seg1 = count;
            memcpy(o + first, plane + idx, (size_t)seg1 * sizeof(float));
            if (count > seg1) memcpy(o + first + seg1, plane, (size_t)(count - seg1) * sizeof(float));
        }
    }
    return count;
}

void sr_ring_write(float *planes, uint32_t planeChannels,
                   int64_t start, uint32_t n,
                   const float *in, uint32_t inChannels, int interleaved) {
    if (!planes || planeChannels == 0 || n == 0) return;
    uint32_t skip = 0;
    if (n > SR_RING_FRAMES) { skip = n - SR_RING_FRAMES; }
    uint32_t count = n - skip;
    int64_t s0 = start + (int64_t)skip;
    uint32_t idx0 = ring_index(s0);
    uint32_t seg1 = SR_RING_FRAMES - idx0;
    if (seg1 > count) seg1 = count;

    for (uint32_t ch = 0; ch < planeChannels; ++ch) {
        float *plane = planes + (size_t)ch * SR_RING_FRAMES;
        if (!in || ch >= inChannels) {
            memset(plane + idx0, 0, (size_t)seg1 * sizeof(float));
            if (count > seg1) memset(plane, 0, (size_t)(count - seg1) * sizeof(float));
            continue;
        }
        if (interleaved) {
            const float *src = in + (size_t)skip * inChannels + ch;
            uint32_t idx = idx0;
            for (uint32_t k = 0; k < count; ++k) {
                plane[idx] = *src;
                src += inChannels;
                idx = (idx + 1u) & SR_RING_MASK;
            }
        } else {
            const float *src = in + (size_t)ch * n + skip;
            memcpy(plane + idx0, src, (size_t)seg1 * sizeof(float));
            if (count > seg1) memcpy(plane, src + seg1, (size_t)(count - seg1) * sizeof(float));
        }
    }
}

int64_t sr_atomic_max_i64(_Atomic int64_t *p, int64_t v) {
    int64_t cur = atomic_load_explicit(p, memory_order_relaxed);
    while (cur < v) {
        if (atomic_compare_exchange_weak_explicit(p, &cur, v, memory_order_release, memory_order_relaxed))
            return v;
    }
    return cur;
}
