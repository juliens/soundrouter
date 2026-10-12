// sr_shm.c — engine-side helpers for the per-device shared memory segment (see sr_shm.h).

#include "sr_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* ------------------------------------------------------------------ timebase */

static _Atomic uint64_t g_ticksToSecondsBits; /* double bits, 0 = not initialised */

static double ticks_to_seconds(void) {
    uint64_t bits = atomic_load_explicit(&g_ticksToSecondsBits, memory_order_relaxed);
    if (bits) return sr_bits_to_double(bits);
    /* mach_timebase_info reads the commpage; it's cheap and non-blocking. Normally this path
     * is only taken from sr_device_shm_open (NRT) which primes the cache. */
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double f = (double)tb.numer / (double)tb.denom * 1e-9;
    atomic_store_explicit(&g_ticksToSecondsBits, sr_double_to_bits(f), memory_order_relaxed);
    return f;
}

int64_t sr_device_now_sample_time(const SRShmHeader *h) {
    uint64_t now = mach_absolute_time();
    int64_t delta = (int64_t)(now - h->anchorHostTime);
    return (int64_t)floor((double)delta * ticks_to_seconds() * h->sampleRate);
}

/* ------------------------------------------------------------------ open / close */

static bool header_matches(const SRShmHeader *h, uint32_t channels, double sampleRate,
                           bool hasPassThru) {
    return h->magic == SR_SHM_MAGIC && h->version == SR_SHM_VERSION &&
           h->channelCount == channels && h->ringFrames == SR_RING_FRAMES &&
           h->sampleRate == sampleRate && h->hasPassThru == (hasPassThru ? 1u : 0u);
}

static int try_reuse(SRDeviceShm *out, const char *name, uint32_t channels, double sampleRate,
                     bool hasPassThru, size_t size) {
    int fd = shm_open(name, O_RDWR);
    if (fd < 0) return errno;
    struct stat st;
    /* Darwin rounds shm object sizes up to the page size. */
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < size) { close(fd); return EINVAL; }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { int e = errno; close(fd); return e; }
    SRShmHeader *h = (SRShmHeader *)p;
    if (!header_matches(h, channels, sampleRate, hasPassThru)) {
        munmap(p, size);
        close(fd);
        return EINVAL;
    }
    out->header = h;
    out->size = size;
    out->fd = fd;
    return 0;
}

int sr_device_shm_open(SRDeviceShm *out, const char *uuidString, uint32_t channels,
                       double sampleRate, bool hasPassThru) {
    if (!out || !uuidString || channels == 0 || channels > SR_MAX_CHANNELS || !(sampleRate > 0))
        return EINVAL;
    memset(out, 0, sizeof(*out));
    out->fd = -1;
    sr_shm_name(uuidString, out->name);
    (void)ticks_to_seconds(); /* prime the timebase cache off the audio thread */

    size_t size = sr_shm_size(channels);
    if (try_reuse(out, out->name, channels, sampleRate, hasPassThru, size) == 0) return 0;

    shm_unlink(out->name);
    int fd = shm_open(out->name, O_CREAT | O_EXCL | O_RDWR, 0666);
    if (fd < 0) return errno;
    /* Best effort: Darwin returns EINVAL for fchmod on POSIX shm objects, but it also does
     * not apply the umask to shm_open's mode, so the segment is already 0666. */
    (void)fchmod(fd, 0666);
    if (ftruncate(fd, (off_t)size) != 0) {
        int e = errno;
        close(fd);
        shm_unlink(out->name);
        return e;
    }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        int e = errno;
        close(fd);
        shm_unlink(out->name);
        return e;
    }
    memset(p, 0, size);
    SRShmHeader *h = (SRShmHeader *)p;
    h->version = SR_SHM_VERSION;
    h->channelCount = channels;
    h->ringFrames = SR_RING_FRAMES;
    h->sampleRate = sampleRate;
    h->anchorHostTime = mach_absolute_time();
    h->hasPassThru = hasPassThru ? 1u : 0u;
    atomic_store_explicit(&h->volumeBits, sr_float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&h->muted, 0, memory_order_relaxed);
    atomic_store_explicit(&h->hostVolumeBits, sr_float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&h->mixWriteFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&h->passThruWriteFrame, 0, memory_order_relaxed);
    /* Magic last: a reader that sees the magic sees an initialised header. */
    atomic_thread_fence(memory_order_release);
    h->magic = SR_SHM_MAGIC;
    atomic_thread_fence(memory_order_seq_cst);

    out->header = h;
    out->size = size;
    out->fd = fd;
    return 0;
}

void sr_device_shm_close(SRDeviceShm *shm) {
    if (!shm) return;
    if (shm->header) munmap(shm->header, shm->size);
    if (shm->fd >= 0) close(shm->fd);
    shm->header = NULL;
    shm->size = 0;
    shm->fd = -1;
}

void sr_device_shm_unlink(const char *uuidString) {
    char name[SR_SHM_NAME_MAX + 1];
    sr_shm_name(uuidString, name);
    shm_unlink(name);
}

/* ------------------------------------------------------------------ ring I/O */

void sr_device_write_mix(SRShmHeader *h, int64_t sampleTime, const float *const *planes,
                         uint32_t frames) {
    int64_t end = sampleTime + (int64_t)frames;
    if (frames > SR_RING_FRAMES) { /* only the last ring period can be kept */
        uint32_t drop = frames - SR_RING_FRAMES;
        sampleTime += drop;
        frames = SR_RING_FRAMES;
        for (uint32_t c = 0; c < h->channelCount; ++c) {
            float *dst = sr_shm_mix_plane(h, c);
            const float *src = planes ? planes[c] : NULL;
            uint32_t start = (uint32_t)((uint64_t)sampleTime & SR_RING_MASK);
            uint32_t first = SR_RING_FRAMES - start;
            if (src) {
                memcpy(dst + start, src + drop, first * sizeof(float));
                memcpy(dst, src + drop + first, (frames - first) * sizeof(float));
            } else {
                memset(dst, 0, SR_RING_FRAMES * sizeof(float));
            }
        }
    } else {
        uint32_t start = (uint32_t)((uint64_t)sampleTime & SR_RING_MASK);
        uint32_t first = SR_RING_FRAMES - start;
        if (first > frames) first = frames;
        for (uint32_t c = 0; c < h->channelCount; ++c) {
            float *dst = sr_shm_mix_plane(h, c);
            const float *src = planes ? planes[c] : NULL;
            if (src) {
                memcpy(dst + start, src, first * sizeof(float));
                if (frames > first) memcpy(dst, src + first, (frames - first) * sizeof(float));
            } else {
                memset(dst + start, 0, first * sizeof(float));
                if (frames > first) memset(dst, 0, (frames - first) * sizeof(float));
            }
        }
    }
    atomic_store_explicit(&h->mixWriteFrame, end, memory_order_release);
}

uint32_t sr_device_read_passthru(SRShmHeader *h, int64_t sampleTime, float *const *planes,
                                 uint32_t frames) {
    uint32_t chans = h->channelCount;
    int64_t lo = sampleTime, hi = sampleTime + (int64_t)frames;
    if (h->hasPassThru) {
        int64_t w = atomic_load_explicit(&h->passThruWriteFrame, memory_order_acquire);
        int64_t oldest = w - (int64_t)SR_RING_FRAMES;
        if (lo < oldest) lo = oldest;
        if (hi > w) hi = w;
    } else {
        hi = lo;
    }
    if (hi < lo) hi = lo;
    uint32_t off = (uint32_t)(lo - sampleTime);
    uint32_t n = (uint32_t)(hi - lo);
    for (uint32_t c = 0; c < chans; ++c) {
        float *dst = planes[c];
        if (!dst) continue;
        if (off) memset(dst, 0, off * sizeof(float));
        if (n) {
            const float *src = sr_shm_passthru_plane(h, c);
            uint32_t start = (uint32_t)((uint64_t)lo & SR_RING_MASK);
            uint32_t first = SR_RING_FRAMES - start;
            if (first > n) first = n;
            memcpy(dst + off, src + start, first * sizeof(float));
            if (n > first) memcpy(dst + off + first, src, (n - first) * sizeof(float));
        }
        if (off + n < frames) memset(dst + off + n, 0, (frames - off - n) * sizeof(float));
    }
    return n;
}
