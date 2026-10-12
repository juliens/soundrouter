// sr_ring.c — lock-free SPSC planar float ring buffer.
//
// Positions are monotonically increasing 64-bit frame counters (never wrap in practice).
// The producer owns writePos, the consumer owns readPos. Each side loads the other's
// counter with acquire and publishes its own with release, so data written before a
// release-store of writePos is visible to a consumer that acquire-loads it (and vice versa
// for the space freed by the consumer).

#include "sr_internal.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SRRing {
    uint32_t channels;
    uint32_t capacity;
    uint32_t mask;
    float   *data;                                 /* channels * capacity */
    _Alignas(64) _Atomic uint64_t writePos;        /* producer */
    _Atomic uint64_t overflows;                    /* producer (relaxed) */
    _Alignas(64) _Atomic uint64_t readPos;         /* consumer */
};

static uint32_t next_pow2(uint32_t v) {
    if (v < 2) return 2;
    if (v > 0x80000000u) return 0x80000000u;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

SRRing *sr_ring_create(uint32_t channels, uint32_t capacityFrames) {
    if (channels == 0) return NULL;
    SRRing *r = (SRRing *)aligned_alloc(64, (sizeof(SRRing) + 63) & ~(size_t)63);
    if (!r) return NULL;
    memset(r, 0, sizeof(*r));
    r->channels = channels;
    r->capacity = next_pow2(capacityFrames);
    r->mask = r->capacity - 1;
    r->data = (float *)calloc((size_t)channels * r->capacity, sizeof(float));
    if (!r->data) { free(r); return NULL; }
    atomic_init(&r->writePos, 0);
    atomic_init(&r->readPos, 0);
    atomic_init(&r->overflows, 0);
    return r;
}

void sr_ring_destroy(SRRing *ring) {
    if (!ring) return;
    free(ring->data);
    free(ring);
}

uint32_t sr_ring_channels(const SRRing *ring) { return ring ? ring->channels : 0; }
uint32_t sr_ring_capacity(const SRRing *ring) { return ring ? ring->capacity : 0; }

static inline float *plane(const SRRing *r, uint32_t ch) {
    return r->data + (size_t)ch * r->capacity;
}

uint32_t sr_ring_writable(const SRRing *ring) {
    uint64_t w = atomic_load_explicit(&((SRRing *)ring)->writePos, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&((SRRing *)ring)->readPos, memory_order_acquire);
    return ring->capacity - (uint32_t)(w - rd);
}

uint32_t sr_ring_readable(const SRRing *ring) {
    uint64_t w = atomic_load_explicit(&((SRRing *)ring)->writePos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&((SRRing *)ring)->readPos, memory_order_relaxed);
    return (uint32_t)(w - rd);
}

/* Reserve space on the producer side; returns frames that fit and counts an overflow. */
static inline uint32_t reserve(SRRing *r, uint32_t frames, uint64_t *wOut) {
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->readPos, memory_order_acquire);
    uint32_t space = r->capacity - (uint32_t)(w - rd);
    *wOut = w;
    if (frames > space) {
        atomic_fetch_add_explicit(&r->overflows, 1, memory_order_relaxed);
        frames = space;
    }
    return frames;
}

uint32_t sr_ring_write(SRRing *ring, const float *const *planes, uint32_t frames) {
    uint64_t w;
    uint32_t n = reserve(ring, frames, &w);
    if (n == 0) return 0;
    uint32_t start = (uint32_t)w & ring->mask;
    uint32_t first = ring->capacity - start;
    if (first > n) first = n;
    for (uint32_t c = 0; c < ring->channels; ++c) {
        float *dst = plane(ring, c);
        const float *src = planes ? planes[c] : NULL;
        if (src) {
            memcpy(dst + start, src, first * sizeof(float));
            if (n > first) memcpy(dst, src + first, (n - first) * sizeof(float));
        } else {
            memset(dst + start, 0, first * sizeof(float));
            if (n > first) memset(dst, 0, (n - first) * sizeof(float));
        }
    }
    atomic_store_explicit(&ring->writePos, w + n, memory_order_release);
    return n;
}

uint32_t sr_ring_write_interleaved(SRRing *ring, const float *src, uint32_t srcChannels,
                                   uint32_t frames) {
    uint64_t w;
    uint32_t n = reserve(ring, frames, &w);
    if (n == 0) return 0;
    uint32_t mask = ring->mask;
    uint32_t start = (uint32_t)w & mask;
    for (uint32_t c = 0; c < ring->channels; ++c) {
        float *dst = plane(ring, c);
        if (c < srcChannels && src) {
            const float *s = src + c;
            for (uint32_t i = 0; i < n; ++i) dst[(start + i) & mask] = s[(size_t)i * srcChannels];
        } else {
            for (uint32_t i = 0; i < n; ++i) dst[(start + i) & mask] = 0.0f;
        }
    }
    atomic_store_explicit(&ring->writePos, w + n, memory_order_release);
    return n;
}

uint32_t sr_ring_peek_n(const SRRing *ring, float *const *planes, uint32_t nplanes,
                        uint32_t frames) {
    uint64_t w = atomic_load_explicit(&((SRRing *)ring)->writePos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&((SRRing *)ring)->readPos, memory_order_relaxed);
    uint32_t avail = (uint32_t)(w - rd);
    uint32_t n = frames < avail ? frames : avail;
    uint32_t start = (uint32_t)rd & ring->mask;
    uint32_t first = ring->capacity - start;
    if (first > n) first = n;
    for (uint32_t c = 0; c < nplanes; ++c) {
        float *dst = planes[c];
        if (!dst) continue;
        if (c < ring->channels) {
            const float *src = plane(ring, c);
            memcpy(dst, src + start, first * sizeof(float));
            if (n > first) memcpy(dst + first, src, (n - first) * sizeof(float));
        } else {
            memset(dst, 0, n * sizeof(float));
        }
    }
    return n;
}

uint32_t sr_ring_peek(const SRRing *ring, float *const *planes, uint32_t frames) {
    return sr_ring_peek_n(ring, planes, ring->channels, frames);
}

void sr_ring_skip(SRRing *ring, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&ring->writePos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&ring->readPos, memory_order_relaxed);
    uint32_t avail = (uint32_t)(w - rd);
    if (frames > avail) frames = avail;
    atomic_store_explicit(&ring->readPos, rd + frames, memory_order_release);
}

uint32_t sr_ring_read(SRRing *ring, float *const *planes, uint32_t frames) {
    uint32_t n = sr_ring_peek_n(ring, planes, ring->channels, frames);
    uint64_t rd = atomic_load_explicit(&ring->readPos, memory_order_relaxed);
    atomic_store_explicit(&ring->readPos, rd + n, memory_order_release);
    return n;
}

uint64_t sr_ring_overflows(const SRRing *ring) {
    return atomic_load_explicit(&((SRRing *)ring)->overflows, memory_order_relaxed);
}
