// sr_shm.h — shared-memory contract between the SoundRouter engine (user agent)
// and the SoundRouter HAL driver (loaded in coreaudiod).
//
// One POSIX shm segment per VirtualDevice. The ENGINE creates it (O_CREAT, mode 0666,
// fchmod after create to defeat umask), sizes it and initialises the header. The DRIVER
// opens it O_RDWR (never creates it). If the driver cannot open it (engine not running,
// sandbox), the device stays visible and returns silence.
//
// Pure C11, no dependencies besides <stdatomic.h>/<stdint.h>. Included by the driver (C)
// and by SRCore (C, exposed to Swift).

#ifndef SR_SHM_H
#define SR_SHM_H

#include <stdint.h>
#include <stdatomic.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SR_SHM_MAGIC          0x53524D31u   /* 'SRM1' */
#define SR_SHM_VERSION        1u
#define SR_MAX_CHANNELS       64u
#define SR_RING_FRAMES        16384u        /* power of two; ring period for mix & passthru */
#define SR_RING_MASK          (SR_RING_FRAMES - 1u)
#define SR_SHM_NAME_MAX       31            /* PSHMNAMLEN on Darwin */

/* Paths / names shared by all components. */
#define SR_APP_SUPPORT_DIRNAME        "SoundRouter"
#define SR_DRIVER_DEVICES_JSON_PATH   "/Library/Application Support/SoundRouter/devices.json"
#define SR_NOTIFY_DEVICES_CHANGED     "io.soundrouter.devices-changed"
#define SR_DEVICE_MANUFACTURER        "SoundRouter"

/*
 * Shm name for a device: "/sr." + first 24 lowercase hex digits of the UUID with dashes
 * removed. e.g. UUID 1B4E28BA-2FA1-11D2-883F-0016D3CCA427 -> "/sr.1b4e28ba2fa111d2883f0016"
 * (28 chars, < PSHMNAMLEN). Use sr_shm_name() to build it.
 */
static inline void sr_shm_name(const char *uuidString, char out[SR_SHM_NAME_MAX + 1]) {
    static const char prefix[] = "/sr.";
    size_t o = 0;
    for (size_t i = 0; prefix[i]; ++i) out[o++] = prefix[i];
    for (size_t i = 0; uuidString[i] && o < 4 + 24; ++i) {
        char c = uuidString[i];
        if (c == '-') continue;
        if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
        out[o++] = c;
    }
    out[o] = '\0';
}

/*
 * CLOCK MODEL
 * The device clock is defined by (anchorHostTime, sampleRate): the sample time of host
 * time h is  (h - anchorHostTime) * sampleRate / hostTicksPerSecond.
 * The engine writes anchorHostTime once when it creates the segment and never changes it
 * while the segment lives (a sample-rate change recreates the segment). The driver, when
 * the segment is mapped at StartIO, derives GetZeroTimeStamp from this same anchor with a
 * period of SR_RING_FRAMES, so driver and engine share one clock with zero drift.
 * If the segment is not mapped at StartIO, the driver uses a private anchor and serves silence.
 *
 * MIX RING (engine -> driver/clients, "input" side of the device)
 *   Frame at device sample time S lives at index (S & SR_RING_MASK) of each channel plane.
 *   Engine renders ahead of "now" and then publishes mixWriteFrame = one past last frame
 *   written (release). Driver ReadInput for [S, S+n): frames with S+k >= mixWriteFrame or
 *   S+k < mixWriteFrame - SR_RING_FRAMES are returned as silence.
 *
 * PASS-THRU RING (clients -> driver -> engine, "output" side)
 *   Driver WriteMix for [S, S+n) writes planes at (S & mask) then publishes
 *   passThruWriteFrame = max(passThruWriteFrame, S+n) (release). Engine reads frames at a
 *   fixed delay behind its render position (see SRCore) and treats missing frames as silence.
 *
 * CONTROLS
 *   Engine writes volume/muted from config. If a client changes the device volume/mute via
 *   the HAL controls, the driver writes the new value into hostVolume/hostMuted and
 *   increments hostControlSeq; the engine adopts it, persists it and mirrors it back into
 *   volume/muted. Same pattern for sample rate via requestedSampleRate (0 = none).
 */

typedef struct SRShmHeader {
    uint32_t magic;                 /* SR_SHM_MAGIC */
    uint32_t version;               /* SR_SHM_VERSION */
    uint32_t channelCount;          /* 1..SR_MAX_CHANNELS (outputChannelCount of the device) */
    uint32_t ringFrames;            /* SR_RING_FRAMES */
    double   sampleRate;            /* nominal rate of the device */
    uint64_t anchorHostTime;        /* mach_absolute_time() at creation, see CLOCK MODEL */
    uint32_t hasPassThru;           /* 1 if device exposes an output stream */
    uint32_t _pad0;

    _Atomic uint64_t engineHeartbeat;      /* mach_absolute_time of last engine cycle */
    _Atomic int64_t  mixWriteFrame;        /* engine: one past last mix frame written */
    _Atomic int64_t  passThruWriteFrame;   /* driver: one past last passthru frame written */
    _Atomic uint32_t driverIORunning;      /* driver: number of running IO clients */
    _Atomic uint32_t driverMapped;         /* driver: 1 once it has mapped the segment */

    _Atomic uint32_t volumeBits;           /* engine: float bits, scalar 0..1 */
    _Atomic uint32_t muted;                /* engine: 0/1 */
    _Atomic uint32_t hostVolumeBits;       /* driver: float bits set by a HAL client */
    _Atomic uint32_t hostMuted;            /* driver: 0/1 set by a HAL client */
    _Atomic uint32_t hostControlSeq;       /* driver: ++ on each host control change */
    _Atomic uint32_t _pad1;
    _Atomic uint64_t requestedSampleRateBits; /* driver: double bits, 0 = none */

    _Atomic uint64_t underrunCount;        /* driver: ReadInput frames served as silence while engine alive */

    uint8_t _reserved[512 - 112];
} SRShmHeader;

_Static_assert(sizeof(SRShmHeader) == 512, "SRShmHeader must be 512 bytes");

/* Layout: header | mix planes [channelCount][SR_RING_FRAMES] float | passthru planes (same). */
static inline size_t sr_shm_size(uint32_t channelCount) {
    return sizeof(SRShmHeader) + 2u * (size_t)channelCount * SR_RING_FRAMES * sizeof(float);
}
static inline float *sr_shm_mix_plane(SRShmHeader *h, uint32_t ch) {
    return (float *)((uint8_t *)h + sizeof(SRShmHeader)) + (size_t)ch * SR_RING_FRAMES;
}
static inline float *sr_shm_passthru_plane(SRShmHeader *h, uint32_t ch) {
    return (float *)((uint8_t *)h + sizeof(SRShmHeader))
         + ((size_t)h->channelCount + ch) * SR_RING_FRAMES;
}
static inline float sr_bits_to_float(uint32_t b) { union { uint32_t u; float f; } x; x.u = b; return x.f; }
static inline uint32_t sr_float_to_bits(float f) { union { uint32_t u; float f; } x; x.f = f; return x.u; }
static inline double sr_bits_to_double(uint64_t b) { union { uint64_t u; double d; } x; x.u = b; return x.d; }
static inline uint64_t sr_double_to_bits(double d) { union { uint64_t u; double d; } x; x.d = d; return x.u; }

/*
 * devices.json (engine -> driver), written atomically by the engine, then
 * notify_post(SR_NOTIFY_DEVICES_CHANGED):
 * {
 *   "schemaVersion": 1,
 *   "devices": [
 *     { "id": "<UUID uppercase>", "name": "Mix 1", "channels": 2,
 *       "sampleRate": 48000, "passThru": true }
 *   ]
 * }
 * Only enabled devices are listed. "id" is the Core Audio device UID.
 */

#ifdef __cplusplus
}
#endif
#endif /* SR_SHM_H */
