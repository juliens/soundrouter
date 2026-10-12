// sr_core.h — real-time audio core of SoundRouter (pure C11).
//
// Everything marked [RT] is safe to call from an audio thread: no allocation, no locks,
// no syscalls, no logging, no Objective-C. Everything marked [NRT] must NOT be called from
// an audio thread. Unit-tested offline in Tests/SRCoreTests.

#ifndef SR_CORE_H
#define SR_CORE_H

#include <stdint.h>
#include <stdbool.h>
#include "sr_shm.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SR_MAX_SOURCES 32u

/* ------------------------------------------------------------------ SPSC ring buffer
 * Planar multichannel float FIFO, one producer thread, one consumer thread.
 * Capacity is rounded up to a power of two. Overflow: write returns frames actually written
 * (excess dropped, overflow counter incremented). */
typedef struct SRRing SRRing;

SRRing  *sr_ring_create(uint32_t channels, uint32_t capacityFrames);          /* [NRT] */
void     sr_ring_destroy(SRRing *ring);                                        /* [NRT] */
uint32_t sr_ring_channels(const SRRing *ring);                                 /* [RT] */
uint32_t sr_ring_capacity(const SRRing *ring);                                 /* [RT] */
/* Producer side. */
uint32_t sr_ring_write(SRRing *ring, const float *const *planes, uint32_t frames);           /* [RT] */
/* Interleaved input; srcChannels may differ from ring channels (extra dropped, missing = 0). */
uint32_t sr_ring_write_interleaved(SRRing *ring, const float *src, uint32_t srcChannels,
                                   uint32_t frames);                                         /* [RT] */
uint32_t sr_ring_writable(const SRRing *ring);                                               /* [RT] */
/* Consumer side. */
uint32_t sr_ring_readable(const SRRing *ring);                                               /* [RT] */
uint32_t sr_ring_read(SRRing *ring, float *const *planes, uint32_t frames);                  /* [RT] */
uint32_t sr_ring_peek(const SRRing *ring, float *const *planes, uint32_t frames);            /* [RT] */
void     sr_ring_skip(SRRing *ring, uint32_t frames);                                        /* [RT] */
uint64_t sr_ring_overflows(const SRRing *ring);                                              /* [RT] */

/* ------------------------------------------------------------------ Drift-compensating resampler
 * Pulls from an SRRing filled by a producer running on a different clock (and possibly a
 * different nominal rate) and produces exactly `frames` output frames at dstRate.
 * A PI controller on the ring fill level (target = targetFillFrames) continuously adjusts the
 * conversion ratio around srcRate/dstRate (clamped to +/- 1%). Interpolation: 4-point,
 * 3rd-order Hermite (or better). On underrun: outputs silence for the missing part, counts
 * an underrun, and waits for the fill to reach target again before resuming (no crackle loop).
 * On large overflow (fill > 3x target): skips ahead to target. */
typedef struct SRDriftResampler SRDriftResampler;

SRDriftResampler *sr_drs_create(uint32_t channels, double srcRate, double dstRate,
                                uint32_t targetFillFrames);                                  /* [NRT] */
void     sr_drs_destroy(SRDriftResampler *r);                                                /* [NRT] */
void     sr_drs_reset(SRDriftResampler *r);                                                  /* [RT] */
/* Writes `frames` frames into out[0..channels-1]. Returns frames produced from real data. */
uint32_t sr_drs_pull(SRDriftResampler *r, SRRing *ring, float *const *out, uint32_t frames); /* [RT] */
double   sr_drs_ratio(const SRDriftResampler *r);        /* current src/dst ratio  [RT] */
uint64_t sr_drs_underruns(const SRDriftResampler *r);                                        /* [RT] */

/* ------------------------------------------------------------------ Meters
 * Peak meters written by the audio thread with relaxed atomics, read+decayed by a UI poller. */
typedef struct SRMeters {
    _Atomic uint32_t sourcePeakBits[SR_MAX_SOURCES][SR_MAX_CHANNELS]; /* per source channel (float bits) */
    _Atomic uint32_t outputPeakBits[SR_MAX_CHANNELS];   /* per output channel (float bits) */
} SRMeters;

/* Swift sees SRMeters as empty (_Atomic fields are not imported): allocate this many bytes. */
static inline size_t sr_meters_size(void) { return sizeof(SRMeters); }
void  sr_meters_reset(SRMeters *m);                                                          /* [RT] */
/* Reader: returns max since last take and resets it to 0 (atomic exchange). */
float sr_meters_take_source(SRMeters *m, uint32_t source, uint32_t channel);                 /* [RT] */
float sr_meters_take_output(SRMeters *m, uint32_t channel);                                  /* [RT] */

/* ------------------------------------------------------------------ Mix plan
 * Immutable description of one device's mix, built off the audio thread and published by
 * atomic pointer swap (see SRPlanSlot). Source indices refer to the order of the
 * `sourcePlanes` array handed to sr_mix_render. */
typedef struct SRRoute {
    uint32_t sourceIndex;
    uint32_t sourceChannel;
    uint32_t outputChannel;
    float    gain;
} SRRoute;

typedef struct SRMixSource {
    uint32_t channels;   /* number of planes provided for this source */
    float    volume;     /* linear 0..1 (or more) */
    bool     muted;
    bool     active;     /* disabled or missing sources contribute nothing */
} SRMixSource;

typedef struct SRMixPlan {
    uint32_t    outputChannels;         /* 1..SR_MAX_CHANNELS */
    float       volume;                 /* device volume */
    bool        muted;                  /* device mute */
    uint32_t    sourceCount;            /* <= SR_MAX_SOURCES */
    SRMixSource sources[SR_MAX_SOURCES];
    uint32_t    routeCount;
    SRRoute     routes[];               /* flexible array */
} SRMixPlan;

SRMixPlan *sr_mix_plan_create(uint32_t routeCapacity);                                       /* [NRT] zeroed */
void       sr_mix_plan_destroy(SRMixPlan *plan);                                             /* [NRT] */
/* Accessors for Swift, which cannot index the flexible `routes` array nor the C `sources`
 * array (imported as a tuple) conveniently. */
/* Swift cannot import C11 _Atomic fields: these give it acquire/release access by address. */
static inline uint32_t sr_atomic_load_u32(const void *p) { return atomic_load_explicit((const _Atomic uint32_t *)p, memory_order_acquire); }
static inline uint64_t sr_atomic_load_u64(const void *p) { return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_acquire); }
static inline void sr_atomic_store_u32(void *p, uint32_t v) { atomic_store_explicit((_Atomic uint32_t *)p, v, memory_order_release); }
static inline void sr_atomic_store_u64(void *p, uint64_t v) { atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_release); }

static inline SRRoute     *sr_mix_plan_routes(SRMixPlan *plan)  { return plan->routes; }
static inline SRMixSource *sr_mix_plan_sources(SRMixPlan *plan) { return plan->sources; }

/* out[ch] = clip( deviceGain * sum_routes( in[src][srcCh] * srcGain * route.gain ) )
 * srcGain = muted||!active ? 0 : volume ; deviceGain = muted ? 0 : volume ; clip to [-1,1].
 * sourcePlanes[s][c] are `frames` floats. out planes are overwritten. meters may be NULL:
 * source peaks are measured after source volume, before routing; output peaks after clip. */
void sr_mix_render(const SRMixPlan *plan, const float *const *const *sourcePlanes,
                   float *const *out, uint32_t frames, SRMeters *meters);                    /* [RT] */

/* ------------------------------------------------------------------ Plan slot (RCU-like)
 * Single reader (audio thread), single writer (control thread).
 * Writer publishes a new pointer; the previous one is retired and freed with `freeFn` only
 * once the reader has passed a quiescent point (reader epoch advanced), from sr_slot_publish
 * or sr_slot_collect on the writer thread. Never frees on the audio thread. */
typedef struct SRPlanSlot SRPlanSlot;

SRPlanSlot *sr_slot_create(void (*freeFn)(void *));                                          /* [NRT] */
void        sr_slot_destroy(SRPlanSlot *slot);        /* frees current + retired      [NRT] */
void        sr_slot_publish(SRPlanSlot *slot, void *ptr);                                    /* [NRT] */
void        sr_slot_collect(SRPlanSlot *slot);        /* free retired if safe          [NRT] */
void       *sr_slot_acquire(SRPlanSlot *slot);        /* begin reader section           [RT] */
void        sr_slot_release(SRPlanSlot *slot);        /* end reader section             [RT] */

/* ------------------------------------------------------------------ Device shm helpers
 * Used by the engine (creator) — the driver has its own copy of the reading side. */
typedef struct SRDeviceShm {
    SRShmHeader *header;
    size_t       size;
    int          fd;
    char         name[SR_SHM_NAME_MAX + 1];
} SRDeviceShm;

/* Opens existing segment if header matches (magic, version, channelCount, sampleRate,
 * hasPassThru) — keeping its anchor — otherwise unlinks and recreates it. 0 on success,
 * errno-style code otherwise. */
int  sr_device_shm_open(SRDeviceShm *out, const char *uuidString, uint32_t channels,
                        double sampleRate, bool hasPassThru);                                /* [NRT] */
void sr_device_shm_close(SRDeviceShm *shm);                    /* munmap, keep segment [NRT] */
void sr_device_shm_unlink(const char *uuidString);             /* remove segment       [NRT] */

/* Current device sample time from the shared anchor (mach_absolute_time based). */
int64_t sr_device_now_sample_time(const SRShmHeader *h);                                     /* [RT] */
/* Write `frames` frames of planar mix at device sample time `sampleTime`, then publish
 * mixWriteFrame = sampleTime + frames. */
void sr_device_write_mix(SRShmHeader *h, int64_t sampleTime, const float *const *planes,
                         uint32_t frames);                                                   /* [RT] */
/* Read `frames` passthru frames at `sampleTime` into planes (silence where not written).
 * Returns frames that contained real data. */
uint32_t sr_device_read_passthru(SRShmHeader *h, int64_t sampleTime, float *const *planes,
                                 uint32_t frames);                                           /* [RT] */

/* ------------------------------------------------------------------ Real-time thread helper
 * Promote the calling thread to THREAD_TIME_CONSTRAINT_POLICY for a cycle of
 * `periodFrames` at `sampleRate`. Returns 0 on success. */
int sr_thread_set_realtime(uint32_t periodFrames, double sampleRate);                        /* [NRT] */

#ifdef __cplusplus
}
#endif
#endif /* SR_CORE_H */
