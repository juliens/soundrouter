// sr_driver.c — SoundRouter AudioServerPlugIn (HAL driver), C11.
//
// Follows the architecture of Apple's NullAudio sample (AudioServerPlugIn object model).
// Publishes one AudioDevice per entry of
// /Library/Application Support/SoundRouter/devices.json and moves audio through the POSIX
// shm segments described in sr_shm.h. It mixes nothing.
//
// Object IDs: plug-in = kAudioObjectPlugInObject (1). Per device, a slot (0..SR_SLOTS-1) and
// a per-slot generation encode every object ID:  id = gen << 12 | slot << 4 | sub.
// This lets the IO path find a device without any lock (atomic slot load + generation check).
//
// Threading:
//   * gLock (pthread mutex) protects the device table and all non-IO device state. It is
//     never taken on the IO path.
//   * The IO path (GetZeroTimeStamp / WillDo / Begin / Do / EndIOOperation) reads
//     d->io, an immutable SRIOState published with release/acquire. Replaced states and
//     replaced shm mappings are retired and freed only while the device has no IO client.
//     Removed devices stay in their slot (flagged) until IO stopped and 5 s elapsed.
//   * A serial dispatch queue runs: devices.json reloads (notify + 2 s mtime poll), the
//     1 s shm (re)open, the 250 ms volume/mute poll, reaping, and deferred
//     RequestDeviceConfigurationChange calls. PropertiesChanged / RequestDeviceConfigurationChange
//     are always called with gLock released.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <os/log.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "sr_shm.h"
#include "sr_devices.h"
#include "sr_ring.h"

/* ------------------------------------------------------------------ configuration */

#ifndef SR_NONINTERLEAVED
/* 0 (default): the HAL-facing physical format is interleaved Float32, as in Apple's NullAudio
 * sample; the driver (de)interleaves to/from the planar shm rings. 1: declare
 * kAudioFormatFlagIsNonInterleaved and treat IO buffers as consecutive channel blocks
 * (untested against coreaudiod). */
#define SR_NONINTERLEAVED 0
#endif

#define SR_SLOTS                 128u
#define SR_GEN_MASK              0xFFFFFu
#define SR_ID_MIN                4096u
#define SR_CLOCK_DOMAIN          0x53527472u        /* 'SRtr': all devices derive from mach_absolute_time */
#define SR_MIN_DB                (-96.0f)
#define SR_CHANGE_APPLY_PENDING  1u
#define SR_TICK_MS               250u
#define SR_MODEL_UID             "io.soundrouter.device"
#define SR_BUNDLE_ID             "io.soundrouter.driver"
#define SR_JSON_MAX_BYTES        (1024 * 1024)
#define SR_MAX_NOTES             512u
#define SR_REMOVED_GRACE_SEC     5.0
#define SR_HOST_PENDING_SEC      2.0

/* J1 test: only when devices.json is missing AND this flag file exists (or the env var is
 * set), expose one hard-coded stereo 48 kHz pass-thru device that loops its output back to
 * its input in driver memory (no engine). Default: expose nothing. */
#define SR_J1_FLAG_PATH          "/Library/Application Support/SoundRouter/j1-test"
#define SR_J1_ENV                "SOUNDROUTER_DRIVER_J1"
#define SR_J1_UID                "53524A31-0000-4000-8000-000000000001"
#define SR_J1_NAME               "SoundRouter J1 Loopback"

#ifdef SR_TESTING
/* In-process harness build (Driver/tests/harness.c): paths come from the harness. */
extern const char *sr_test_json_path(void);
extern const char *sr_test_j1_path(void);
#define SR_JSON_PATH sr_test_json_path()
#define SR_J1_PATH   sr_test_j1_path()
#else
#define SR_JSON_PATH SR_DRIVER_DEVICES_JSON_PATH
#define SR_J1_PATH   SR_J1_FLAG_PATH
#endif

enum {
    SUB_DEVICE = 0, SUB_STREAM_IN = 1, SUB_STREAM_OUT = 2,
    SUB_VOL_IN = 3, SUB_MUTE_IN = 4, SUB_VOL_OUT = 5, SUB_MUTE_OUT = 6
};

/* ------------------------------------------------------------------ types */

typedef struct SRIOState {
    SRShmHeader *hdr;          /* NULL -> silence in, drop out */
    int          readOnly;     /* segment mapped read-only: never write to hdr */
    int          engineClock;  /* anchor == hdr->anchorHostTime */
    int          loopback;     /* J1: read input from the pass-thru planes */
    uint32_t     channels;
    double       sampleRate;
    uint64_t     anchor;
    double       ticksPerRing;
    UInt64       seed;
} SRIOState;

typedef struct SRRetired {
    struct SRRetired *next;
    void             *ptr;
    size_t            mapLen;  /* > 0: munmap, else free */
} SRRetired;

typedef struct SRDevice {
    uint32_t     slot, gen;
    AudioObjectID idDevice;
    SRDevDesc    desc;                         /* last values seen in devices.json */
    char         shmName[SR_SHM_NAME_MAX + 1];
    int          passThru;                     /* immutable (change => recreate) */
    uint32_t     channels;                     /* current; changes only in Perform */
    double       sampleRate;                   /* current; changes only in Perform */
    uint32_t     pendingChannels;              /* 0 = none */
    double       pendingRate;                  /* 0 = none */
    int          removed;
    uint64_t     removedAt;
    SRShmHeader *map;                          /* current mapping (may be incompatible) */
    size_t       mapLen;
    int          mapReadOnly;                  /* O_RDWR denied (e.g. umask 022): input only */
    SRShmHeader *loop;                         /* J1 private loopback block */
    SRRetired   *retired;
    float        volume;                       /* cached control values */
    int          mute;
    int          hostPending;                  /* host set a value the engine has not mirrored yet */
    uint64_t     hostPendingAt;
    float        hostVolume;
    int          hostMute;
    int          streamInActive, streamOutActive;
    _Atomic(SRIOState *) io;
    _Atomic uint32_t     ioClients;
} SRDevice;

typedef struct SRNotes {
    uint32_t n;
    struct { AudioObjectID obj; AudioObjectPropertyAddress addr; } e[SR_MAX_NOTES];
} SRNotes;

/* ------------------------------------------------------------------ globals */

static AudioServerPlugInHostRef gHost;
static pthread_mutex_t  gLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(SRDevice *) gSlots[SR_SLOTS];
static uint32_t         gSlotGen[SR_SLOTS];
static _Atomic uint32_t gRefCount = 1;
static _Atomic int      gInitialized;
static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;
static int              gNotifyToken = -1;
static double           gTicksPerSecond = 1e9;
static uint64_t         gFreshTicks;           /* 100 ms in host ticks */
static uint64_t         gTick;
static os_log_t         gLog;
static int              gLastLoadError;

static struct {
    int exists;
    int j1;
    ino_t ino;
    long long mtimeSec, mtimeNsec;
    off_t size;
} gFileSig;

/* ------------------------------------------------------------------ helpers */

static inline AudioObjectID mkid(uint32_t gen, uint32_t slot, uint32_t sub) {
    return (AudioObjectID)((gen << 12) | (slot << 4) | sub);
}

static inline double secs_since(uint64_t then, uint64_t now) {
    return now > then ? (double)(now - then) / gTicksPerSecond : 0.0;
}

static inline int engine_fresh(const SRShmHeader *h, uint64_t now) {
    uint64_t hb = atomic_load_explicit(&((SRShmHeader *)h)->engineHeartbeat, memory_order_relaxed);
    return hb != 0 && (hb >= now || now - hb < gFreshTicks);
}

/* Lock-free: usable on the IO path. Does not filter removed devices. */
static inline SRDevice *lookup_io(AudioObjectID id, uint32_t *sub) {
    if (id < SR_ID_MIN) return NULL;
    uint32_t slot = (id >> 4) & 0xFFu;
    if (slot >= SR_SLOTS) return NULL;
    SRDevice *d = atomic_load_explicit(&gSlots[slot], memory_order_acquire);
    if (!d || d->gen != (id >> 12)) return NULL;
    if (sub) *sub = id & 0xFu;
    return d;
}

/* gLock held. Filters removed devices and sub-objects that do not exist. */
static SRDevice *lookup_obj(AudioObjectID id, uint32_t *sub) {
    uint32_t s = 0;
    SRDevice *d = lookup_io(id, &s);
    if (!d || d->removed) return NULL;
    switch (s) {
        case SUB_DEVICE: case SUB_STREAM_IN: case SUB_VOL_IN: case SUB_MUTE_IN: break;
        case SUB_STREAM_OUT: case SUB_VOL_OUT: case SUB_MUTE_OUT: if (!d->passThru) return NULL; break;
        default: return NULL;
    }
    *sub = s;
    return d;
}

static void notes_add(SRNotes *n, AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    if (n->n >= SR_MAX_NOTES) return;
    n->e[n->n].obj = obj;
    n->e[n->n].addr.mSelector = sel;
    n->e[n->n].addr.mScope = scope;
    n->e[n->n].addr.mElement = kAudioObjectPropertyElementMain;
    n->n++;
}

static void notes_flush(SRNotes *n) {
    if (!gHost || !atomic_load(&gInitialized)) { n->n = 0; return; }
    for (uint32_t i = 0; i < n->n; ++i)
        gHost->PropertiesChanged(gHost, n->e[i].obj, 1, &n->e[i].addr);
    n->n = 0;
}

/* +1 CFString for the HAL (caller releases); never NULL. */
static CFStringRef make_cfstr(const char *s) {
    CFStringRef r = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    if (!r) r = CFStringCreateWithCString(NULL, s, kCFStringEncodingISOLatin1);
    return r ? r : CFSTR(SR_DEFAULT_NAME);
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static float scalar_to_db(float s) {
    if (!(s > 0.0f)) return SR_MIN_DB;
    float db = 20.0f * log10f(s);
    return db < SR_MIN_DB ? SR_MIN_DB : (db > 0.0f ? 0.0f : db);
}

static float db_to_scalar(float db) {
    if (!(db > SR_MIN_DB)) return 0.0f;
    if (db >= 0.0f) return 1.0f;
    return powf(10.0f, db / 20.0f);
}

static void fill_asbd(AudioStreamBasicDescription *f, double rate, uint32_t ch) {
    memset(f, 0, sizeof *f);
    f->mSampleRate = rate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
                    | (SR_NONINTERLEAVED ? kAudioFormatFlagIsNonInterleaved : 0);
    f->mBytesPerFrame = SR_NONINTERLEAVED ? (UInt32)sizeof(float) : (UInt32)(sizeof(float) * ch);
    f->mBytesPerPacket = f->mBytesPerFrame;
    f->mFramesPerPacket = 1;
    f->mChannelsPerFrame = ch;
    f->mBitsPerChannel = 32;
}

/* ------------------------------------------------------------------ retire / free (gLock held) */

static void retire_locked(SRDevice *d, void *ptr, size_t mapLen) {
    if (!ptr) return;
    SRRetired *r = malloc(sizeof *r);
    if (!r) return; /* leak rather than risk a use-after-free */
    r->ptr = ptr;
    r->mapLen = mapLen;
    r->next = d->retired;
    d->retired = r;
}

static void reap_locked(SRDevice *d) {
    if (atomic_load(&d->ioClients) != 0) return;
    SRRetired *r = d->retired;
    d->retired = NULL;
    while (r) {
        SRRetired *next = r->next;
        if (r->mapLen) munmap(r->ptr, r->mapLen); else free(r->ptr);
        free(r);
        r = next;
    }
}

static int map_compatible(const SRDevice *d) {
    const SRShmHeader *h = d->map;
    return h && h->magic == SR_SHM_MAGIC && h->version == SR_SHM_VERSION
        && h->channelCount == d->channels && h->ringFrames == SR_RING_FRAMES
        && h->sampleRate == d->sampleRate && d->mapLen >= sr_shm_size(d->channels);
}

/* Current mapping if valid and writable, else NULL. */
static SRShmHeader *wmap(const SRDevice *d) {
    return (d->map && !d->mapReadOnly && d->map->magic == SR_SHM_MAGIC) ? d->map : NULL;
}

/* Publishes a fresh immutable IO state. newPrivateAnchor: restart the private clock at now. */
static void publish_state_locked(SRDevice *d, int newPrivateAnchor) {
    SRIOState *old = atomic_load_explicit(&d->io, memory_order_relaxed);
    SRIOState *s = calloc(1, sizeof *s);
    if (!s) return;
    s->channels = d->channels;
    s->sampleRate = d->sampleRate;
    s->ticksPerRing = gTicksPerSecond / d->sampleRate * (double)SR_RING_FRAMES;
    if (d->loop) {
        s->hdr = d->loop;
        s->loopback = 1;
    } else if (map_compatible(d)) {
        s->hdr = d->map;
        s->readOnly = d->mapReadOnly;
        s->engineClock = 1;
        s->anchor = d->map->anchorHostTime;
    }
    if (!s->engineClock) {
        if (!newPrivateAnchor && old && !old->engineClock && old->sampleRate == s->sampleRate) {
            s->anchor = old->anchor;
        } else {
            s->anchor = mach_absolute_time();
            /* loopback timeline restarts: old pass-thru frames must not look "in the future" */
            if (d->loop && atomic_load(&d->ioClients) <= 1) {
                memset((uint8_t *)d->loop + sizeof(SRShmHeader), 0, sr_shm_size(d->loop->channelCount) - sizeof(SRShmHeader));
                atomic_store_explicit(&d->loop->passThruWriteFrame, 0, memory_order_release);
            }
        }
    }
    s->seed = old ? old->seed + ((old->anchor != s->anchor || old->sampleRate != s->sampleRate) ? 1u : 0u) : 1u;
    atomic_store_explicit(&d->io, s, memory_order_release);
    if (old) retire_locked(d, old, 0);
}

static SRShmHeader *alloc_loop_block(uint32_t channels, double rate) {
    SRShmHeader *h = calloc(1, sr_shm_size(channels));
    if (!h) return NULL;
    h->magic = SR_SHM_MAGIC;
    h->version = SR_SHM_VERSION;
    h->channelCount = channels;
    h->ringFrames = SR_RING_FRAMES;
    h->sampleRate = rate;
    h->hasPassThru = 1;
    atomic_store(&h->volumeBits, sr_float_to_bits(1.0f));
    return h;
}

/* Opens / re-opens the device segment if a new one exists. Returns 1 if the mapping changed. */
static int refresh_mapping_locked(SRDevice *d) {
    if (d->loop || d->removed) return 0;
    int ro = 0;
    int fd = shm_open(d->shmName, O_RDWR);
    if (fd < 0 && errno == EACCES) {        /* segment not group/other-writable: input still works */
        fd = shm_open(d->shmName, O_RDONLY);
        ro = 1;
    }
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(SRShmHeader)) { close(fd); return 0; }
    void *peek = mmap(NULL, sizeof(SRShmHeader), PROT_READ, MAP_SHARED, fd, 0);
    if (peek == MAP_FAILED) { close(fd); return 0; }
    const SRShmHeader *ph = peek;
    uint32_t ch = ph->channelCount;
    int valid = ph->magic == SR_SHM_MAGIC && ph->version == SR_SHM_VERSION
             && ch >= 1 && ch <= SR_MAX_CHANNELS && ph->ringFrames == SR_RING_FRAMES
             && (size_t)st.st_size >= sr_shm_size(ch);
    int same = d->map && ph->anchorHostTime == d->map->anchorHostTime
            && ph->sampleRate == d->map->sampleRate && ph->channelCount == d->map->channelCount
            && d->map->magic == SR_SHM_MAGIC;
    munmap(peek, sizeof(SRShmHeader));
    if (!valid || same) { close(fd); return 0; }

    size_t len = sr_shm_size(ch);
    void *m = mmap(NULL, len, ro ? PROT_READ : (PROT_READ | PROT_WRITE), MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return 0;
    SRShmHeader *h = m;
    if (h->channelCount != ch || h->magic != SR_SHM_MAGIC) { munmap(m, len); return 0; }

    SRShmHeader *oldMap = d->map;
    size_t oldLen = d->mapLen;
    d->map = h;
    d->mapLen = len;
    d->mapReadOnly = ro;
    if (!ro) {
        atomic_store(&h->driverMapped, 1u);
        atomic_store(&h->driverIORunning, atomic_load(&d->ioClients));
    }
    os_log_info(gLog, "mapped %{public}s (ch %u, rate %.0f%{public}s)", d->shmName, ch, h->sampleRate,
                ro ? ", READ-ONLY: engine must create the segment 0666 (umask)" : "");
    publish_state_locked(d, 0);          /* drops references to oldMap */
    if (oldMap) retire_locked(d, oldMap, oldLen);
    return 1;
}

/* ------------------------------------------------------------------ device table (gLock held) */

static SRDevice *create_device_locked(const SRDevDesc *desc) {
    uint32_t slot = SR_SLOTS;
    for (uint32_t i = 0; i < SR_SLOTS; ++i)
        if (!atomic_load_explicit(&gSlots[i], memory_order_relaxed)) { slot = i; break; }
    if (slot == SR_SLOTS) { os_log_error(gLog, "no free device slot"); return NULL; }

    SRDevice *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    uint32_t gen = (gSlotGen[slot] + 1u) & SR_GEN_MASK;
    if (gen == 0) gen = 1;
    gSlotGen[slot] = gen;
    d->slot = slot;
    d->gen = gen;
    d->idDevice = mkid(gen, slot, SUB_DEVICE);
    d->desc = *desc;
    sr_shm_name(desc->id, d->shmName);
    d->passThru = desc->passThru ? 1 : 0;
    d->channels = desc->channels;
    d->sampleRate = desc->sampleRate;
    d->volume = 1.0f;
    d->streamInActive = 1;
    d->streamOutActive = 1;
    if (strcmp(desc->id, SR_J1_UID) == 0) {
        d->loop = alloc_loop_block(d->channels, d->sampleRate);
        if (!d->loop) { free(d); return NULL; }
    }
    publish_state_locked(d, 1);
    atomic_store_explicit(&gSlots[slot], d, memory_order_release);
    refresh_mapping_locked(d);
    os_log_info(gLog, "device added %{public}s '%{public}s' ch %u rate %.0f passThru %d",
                desc->id, desc->name, desc->channels, desc->sampleRate, d->passThru);
    return d;
}

static void remove_device_locked(SRDevice *d, uint64_t now) {
    d->removed = 1;
    d->removedAt = now;
    os_log_info(gLog, "device removed %{public}s", d->desc.id);
}

static void free_device_locked(SRDevice *d) {
    atomic_store_explicit(&gSlots[d->slot], NULL, memory_order_release);
    reap_locked(d);
    SRIOState *s = atomic_load(&d->io);
    free(s);
    if (d->map) munmap(d->map, d->mapLen);
    free(d->loop);
    free(d);
}

static uint32_t live_devices_locked(SRDevice **out, uint32_t max) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < SR_SLOTS && n < max; ++i) {
        SRDevice *d = atomic_load_explicit(&gSlots[i], memory_order_relaxed);
        if (d && !d->removed) out[n++] = d;
    }
    return n;
}

/* ------------------------------------------------------------------ devices.json */

static void file_signature(int *exists, int *j1, ino_t *ino, long long *ms, long long *mns, off_t *size) {
    struct stat st;
    *exists = stat(SR_JSON_PATH, &st) == 0;
    *ino = *exists ? st.st_ino : 0;
    *ms = *exists ? (long long)st.st_mtimespec.tv_sec : 0;
    *mns = *exists ? (long long)st.st_mtimespec.tv_nsec : 0;
    *size = *exists ? st.st_size : 0;
    const char *env = getenv(SR_J1_ENV);
    *j1 = (env && env[0] == '1') || access(SR_J1_PATH, F_OK) == 0;
}

static int file_signature_changed(void) {
    int exists, j1; ino_t ino; long long ms, mns; off_t size;
    file_signature(&exists, &j1, &ino, &ms, &mns, &size);
    return exists != gFileSig.exists || j1 != gFileSig.j1 || ino != gFileSig.ino
        || ms != gFileSig.mtimeSec || mns != gFileSig.mtimeNsec || size != gFileSig.size;
}

static void record_file_signature(void) {
    file_signature(&gFileSig.exists, &gFileSig.j1, &gFileSig.ino, &gFileSig.mtimeSec,
                   &gFileSig.mtimeNsec, &gFileSig.size);
}

/* 0: *n devices loaded (possibly 0). -1: keep the current list. */
static int load_device_list(SRDevDesc *list, uint32_t *n) {
    *n = 0;
    int fd = open(SR_JSON_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        int err = errno;
        if (err == ENOENT) {
            if (gFileSig.j1) {
                memset(&list[0], 0, sizeof list[0]);
                memcpy(list[0].id, SR_J1_UID, sizeof SR_J1_UID);
                memcpy(list[0].name, SR_J1_NAME, sizeof SR_J1_NAME);
                list[0].channels = 2;
                list[0].sampleRate = 48000.0;
                list[0].passThru = 1;
                *n = 1;
            }
            gLastLoadError = 0;
            return 0;
        }
        if (err != gLastLoadError)
            os_log_error(gLog, "cannot open %{public}s: errno %d (sandbox?)", SR_JSON_PATH, err);
        gLastLoadError = err;
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > SR_JSON_MAX_BYTES) {
        close(fd);
        os_log_error(gLog, "devices.json: bad size");
        return -1;
    }
    size_t len = (size_t)st.st_size;
    char *buf = malloc(len);
    if (!buf) { close(fd); return -1; }
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, buf + got, len - got);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    int rc = sr_devices_json_parse(buf, got, list, SR_MAX_DEVICES, n);
    free(buf);
    if (rc != 0) { os_log_error(gLog, "devices.json: parse error, keeping current devices"); return -1; }
    gLastLoadError = 0;
    return 0;
}

/* Runs on gQueue. */
static void reload_devices(void) {
    SRDevDesc *list = calloc(SR_MAX_DEVICES, sizeof *list);
    SRDevDesc *cur = calloc(SR_SLOTS, sizeof *cur);
    SRDiffOp *ops = calloc(SR_SLOTS + SR_MAX_DEVICES, sizeof *ops);
    SRNotes *notes = calloc(1, sizeof *notes);
    SRDevice *curDev[SR_SLOTS];
    AudioObjectID cfg[SR_SLOTS];
    uint32_t nNew = 0, nCfg = 0;
    if (!list || !cur || !ops || !notes) goto out;

    record_file_signature();
    if (load_device_list(list, &nNew) != 0) goto out;

    pthread_mutex_lock(&gLock);
    uint64_t now = mach_absolute_time();
    uint32_t nCur = live_devices_locked(curDev, SR_SLOTS);
    for (uint32_t i = 0; i < nCur; ++i) cur[i] = curDev[i]->desc;
    uint32_t nOps = sr_devlist_diff(cur, nCur, list, nNew, ops, SR_SLOTS + SR_MAX_DEVICES);
    int listChanged = 0;
    for (uint32_t k = 0; k < nOps; ++k) {
        const SRDiffOp *op = &ops[k];
        switch (op->kind) {
            case SR_DIFF_REMOVE:
                remove_device_locked(curDev[op->oldIndex], now);
                listChanged = 1;
                break;
            case SR_DIFF_RECREATE:
                remove_device_locked(curDev[op->oldIndex], now);
                create_device_locked(&list[op->newIndex]);
                listChanged = 1;
                break;
            case SR_DIFF_ADD:
                if (create_device_locked(&list[op->newIndex])) listChanged = 1;
                break;
            case SR_DIFF_UPDATE: {
                SRDevice *d = curDev[op->oldIndex];
                const SRDevDesc *nd = &list[op->newIndex];
                d->desc = *nd;
                if (op->changes & SR_CHG_NAME) notes_add(notes, d->idDevice, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
                if (op->changes & (SR_CHG_CHANNELS | SR_CHG_RATE)) {
                    d->pendingChannels = nd->channels;
                    d->pendingRate = nd->sampleRate;
                    if (nCfg < SR_SLOTS) cfg[nCfg++] = d->idDevice;
                }
                break;
            }
        }
    }
    pthread_mutex_unlock(&gLock);

    if (listChanged) {
        notes_add(notes, kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
        notes_add(notes, kAudioObjectPlugInObject, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal);
    }
    notes_flush(notes);
    if (gHost && atomic_load(&gInitialized))
        for (uint32_t i = 0; i < nCfg; ++i)
            gHost->RequestDeviceConfigurationChange(gHost, cfg[i], SR_CHANGE_APPLY_PENDING, NULL);
out:
    free(list); free(cur); free(ops); free(notes);
}


static void request_config_f(void *ctx) {
    AudioObjectID id = (AudioObjectID)(uintptr_t)ctx;
    if (gHost) gHost->RequestDeviceConfigurationChange(gHost, id, SR_CHANGE_APPLY_PENDING, NULL);
}

/* ------------------------------------------------------------------ periodic maintenance */

static void poll_controls_locked(SRDevice *d, uint64_t now, SRNotes *notes) {
    SRShmHeader *h = d->map;
    if (!h || h->magic != SR_SHM_MAGIC || !engine_fresh(h, now)) return;
    float v = clampf(sr_bits_to_float(atomic_load_explicit(&h->volumeBits, memory_order_acquire)), 0.0f, 1.0f);
    int m = atomic_load_explicit(&h->muted, memory_order_acquire) != 0;
    if (d->hostPending) {
        if ((v == d->hostVolume && m == d->hostMute) || secs_since(d->hostPendingAt, now) > SR_HOST_PENDING_SEC)
            d->hostPending = 0;
        else
            return;
    }
    if (v != d->volume) {
        d->volume = v;
        notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_IN), kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
        notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_IN), kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal);
        if (d->passThru) {
            notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_OUT), kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
            notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_OUT), kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal);
        }
    }
    if (m != d->mute) {
        d->mute = m;
        notes_add(notes, mkid(d->gen, d->slot, SUB_MUTE_IN), kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
        if (d->passThru)
            notes_add(notes, mkid(d->gen, d->slot, SUB_MUTE_OUT), kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
    }
}

static void tick_f(void *ctx) {
    (void)ctx;
    SRNotes *notes = calloc(1, sizeof *notes);
    if (!notes) return;
    gTick++;
    int everySecond = (gTick % (1000u / SR_TICK_MS)) == 0;

    pthread_mutex_lock(&gLock);
    uint64_t now = mach_absolute_time();
    for (uint32_t i = 0; i < SR_SLOTS; ++i) {
        SRDevice *d = atomic_load_explicit(&gSlots[i], memory_order_relaxed);
        if (!d) continue;
        if (d->removed) {
            if (atomic_load(&d->ioClients) == 0 && secs_since(d->removedAt, now) > SR_REMOVED_GRACE_SEC)
                free_device_locked(d);
            continue;
        }
        if (everySecond) {
            refresh_mapping_locked(d);
            /* the engine may have invalidated the segment header: keep IO state consistent */
            SRIOState *s = atomic_load_explicit(&d->io, memory_order_relaxed);
            if (!d->loop && s && (s->hdr != NULL) != map_compatible(d)) publish_state_locked(d, 0);
        }
        poll_controls_locked(d, now, notes);
        reap_locked(d);
    }
    pthread_mutex_unlock(&gLock);
    notes_flush(notes);
    free(notes);

    if ((gTick % (2000u / SR_TICK_MS)) == 0 && file_signature_changed())
        reload_devices();
}

/* ------------------------------------------------------------------ properties */

#define PUT(type, expr) do { \
        if (outData) { \
            if (inSize < (UInt32)sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type *)outData = (expr); \
        } \
        *outSize = (UInt32)sizeof(type); \
        return kAudioHardwareNoError; \
    } while (0)

static OSStatus put_ids(const AudioObjectID *ids, UInt32 count, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (outData) {
        UInt32 n = inSize / (UInt32)sizeof(AudioObjectID);
        if (n > count) n = count;
        memcpy(outData, ids, n * sizeof(AudioObjectID));
        *outSize = n * (UInt32)sizeof(AudioObjectID);
    } else {
        *outSize = count * (UInt32)sizeof(AudioObjectID);
    }
    return kAudioHardwareNoError;
}

static OSStatus plugin_get(const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                           UInt32 inSize, UInt32 *outSize, void *outData) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(SR_DEVICE_MANUFACTURER));
        case kAudioPlugInPropertyResourceBundle: PUT(CFStringRef, CFSTR(""));
        case kAudioPlugInPropertyBoxList:
            *outSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            SRDevice *devs[SR_SLOTS];
            AudioObjectID ids[SR_SLOTS];
            uint32_t n = live_devices_locked(devs, SR_SLOTS);
            for (uint32_t i = 0; i < n; ++i) ids[i] = devs[i]->idDevice;
            return put_ids(ids, n, inSize, outSize, outData);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (outData) {
                if (qSize < sizeof(CFStringRef) || !qData) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *(const CFStringRef *)qData;
                char buf[SR_DEVDESC_ID_MAX];
                if (uid && CFStringGetCString(uid, buf, sizeof buf, kCFStringEncodingUTF8)) {
                    SRDevice *devs[SR_SLOTS];
                    uint32_t n = live_devices_locked(devs, SR_SLOTS);
                    for (uint32_t i = 0; i < n; ++i)
                        if (strcmp(devs[i]->desc.id, buf) == 0) { found = devs[i]->idDevice; break; }
                }
            }
            PUT(AudioObjectID, found);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static void device_scope_objects(SRDevice *d, AudioObjectPropertyScope scope, int streamsOnly,
                                 AudioObjectID *ids, UInt32 *n) {
    *n = 0;
    int in = scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput;
    int out = d->passThru && (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput);
    if (in) ids[(*n)++] = mkid(d->gen, d->slot, SUB_STREAM_IN);
    if (out) ids[(*n)++] = mkid(d->gen, d->slot, SUB_STREAM_OUT);
    if (streamsOnly) return;
    if (in) { ids[(*n)++] = mkid(d->gen, d->slot, SUB_VOL_IN); ids[(*n)++] = mkid(d->gen, d->slot, SUB_MUTE_IN); }
    if (out) { ids[(*n)++] = mkid(d->gen, d->slot, SUB_VOL_OUT); ids[(*n)++] = mkid(d->gen, d->slot, SUB_MUTE_OUT); }
}

static OSStatus device_get(SRDevice *d, const AudioObjectPropertyAddress *a,
                           UInt32 inSize, UInt32 *outSize, void *outData) {
    AudioObjectID ids[8];
    UInt32 n;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectPlugInObject);
        case kAudioObjectPropertyName:
            PUT(CFStringRef, make_cfstr(d->desc.name));
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(SR_DEVICE_MANUFACTURER));
        case kAudioDevicePropertyDeviceUID:
            PUT(CFStringRef, make_cfstr(d->desc.id));
        case kAudioDevicePropertyModelUID: PUT(CFStringRef, CFSTR(SR_MODEL_UID));
        case kAudioObjectPropertyOwnedObjects:
            device_scope_objects(d, a->mScope, 0, ids, &n);
            return put_ids(ids, n, inSize, outSize, outData);
        case kAudioDevicePropertyStreams:
            device_scope_objects(d, a->mScope, 1, ids, &n);
            return put_ids(ids, n, inSize, outSize, outData);
        case kAudioObjectPropertyControlList:
            device_scope_objects(d, kAudioObjectPropertyScopeGlobal, 0, ids, &n);
            return put_ids(ids + (d->passThru ? 2 : 1), n - (d->passThru ? 2 : 1), inSize, outSize, outData);
        case kAudioDevicePropertyRelatedDevices:
            return put_ids(&d->idDevice, 1, inSize, outSize, outData);
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: PUT(UInt32, SR_CLOCK_DOMAIN);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1u);
        case kAudioDevicePropertyDeviceIsRunning: PUT(UInt32, atomic_load(&d->ioClients) > 0 ? 1u : 0u);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            PUT(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? (UInt32)d->passThru : 1u);
        case kAudioDevicePropertyLatency: PUT(UInt32, 0u);
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0u);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, d->sampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 cnt = SR_SUPPORTED_RATE_COUNT;
            if (outData) {
                UInt32 m = inSize / (UInt32)sizeof(AudioValueRange);
                if (m > cnt) m = cnt;
                AudioValueRange *r = outData;
                for (UInt32 i = 0; i < m; ++i) { r[i].mMinimum = sr_supported_rates[i]; r[i].mMaximum = sr_supported_rates[i]; }
                cnt = m;
            }
            *outSize = cnt * (UInt32)sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyIsHidden: PUT(UInt32, 0u);
        case kAudioDevicePropertyClockIsStable: PUT(UInt32, 1u);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, SR_RING_FRAMES);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 sz = 2 * (UInt32)sizeof(UInt32);
            if (outData) {
                if (inSize < sz) return kAudioHardwareBadPropertySizeError;
                ((UInt32 *)outData)[0] = 1;
                ((UInt32 *)outData)[1] = d->channels >= 2 ? 2 : 1;
            }
            *outSize = sz;
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 sz = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                               + d->channels * sizeof(AudioChannelDescription));
            if (outData) {
                if (inSize < sz) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout *l = outData;
                memset(l, 0, sz);
                l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                l->mNumberChannelDescriptions = d->channels;
                for (UInt32 i = 0; i < d->channels; ++i) {
                    AudioChannelLabel lab;
                    if (d->channels == 1) lab = kAudioChannelLabel_Mono;
                    else if (i == 0) lab = kAudioChannelLabel_Left;
                    else if (i == 1) lab = kAudioChannelLabel_Right;
                    else lab = kAudioChannelLabel_Discrete_0 + i;
                    l->mChannelDescriptions[i].mChannelLabel = lab;
                }
            }
            *outSize = sz;
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus stream_get(SRDevice *d, uint32_t sub, const AudioObjectPropertyAddress *a,
                           UInt32 inSize, UInt32 *outSize, void *outData) {
    int isIn = sub == SUB_STREAM_IN;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, d->idDevice);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            PUT(CFStringRef, isIn ? CFSTR("SoundRouter Input") : CFSTR("SoundRouter Output"));
        case kAudioStreamPropertyIsActive: PUT(UInt32, (UInt32)(isIn ? d->streamInActive : d->streamOutActive));
        case kAudioStreamPropertyDirection: PUT(UInt32, isIn ? 1u : 0u);
        case kAudioStreamPropertyTerminalType:
            PUT(UInt32, isIn ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1u);
        case kAudioStreamPropertyLatency: PUT(UInt32, 0u);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            UInt32 sz = (UInt32)sizeof(AudioStreamBasicDescription);
            if (outData) {
                if (inSize < sz) return kAudioHardwareBadPropertySizeError;
                fill_asbd(outData, d->sampleRate, d->channels);
            }
            *outSize = sz;
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 cnt = SR_SUPPORTED_RATE_COUNT;
            if (outData) {
                UInt32 m = inSize / (UInt32)sizeof(AudioStreamRangedDescription);
                if (m > cnt) m = cnt;
                AudioStreamRangedDescription *r = outData;
                for (UInt32 i = 0; i < m; ++i) {
                    fill_asbd(&r[i].mFormat, sr_supported_rates[i], d->channels);
                    r[i].mSampleRateRange.mMinimum = sr_supported_rates[i];
                    r[i].mSampleRateRange.mMaximum = sr_supported_rates[i];
                }
                cnt = m;
            }
            *outSize = cnt * (UInt32)sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static float effective_volume_locked(SRDevice *d) {
    SRShmHeader *h = d->map;
    if (h && h->magic == SR_SHM_MAGIC && !d->hostPending && engine_fresh(h, mach_absolute_time()))
        return clampf(sr_bits_to_float(atomic_load_explicit(&h->volumeBits, memory_order_acquire)), 0.0f, 1.0f);
    return d->volume;
}

static int effective_mute_locked(SRDevice *d) {
    SRShmHeader *h = d->map;
    if (h && h->magic == SR_SHM_MAGIC && !d->hostPending && engine_fresh(h, mach_absolute_time()))
        return atomic_load_explicit(&h->muted, memory_order_acquire) != 0;
    return d->mute;
}

static OSStatus control_get(SRDevice *d, uint32_t sub, const AudioObjectPropertyAddress *a,
                            UInt32 inSize, UInt32 *outSize, void *outData) {
    int isVol = sub == SUB_VOL_IN || sub == SUB_VOL_OUT;
    AudioObjectPropertyScope scope = (sub == SUB_VOL_IN || sub == SUB_MUTE_IN)
                                   ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            PUT(AudioClassID, isVol ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass:
            PUT(AudioClassID, isVol ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, d->idDevice);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope: PUT(AudioObjectPropertyScope, scope);
        case kAudioControlPropertyElement: PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        default: break;
    }
    if (isVol) {
        switch (a->mSelector) {
            case kAudioLevelControlPropertyScalarValue: PUT(Float32, effective_volume_locked(d));
            case kAudioLevelControlPropertyDecibelValue: PUT(Float32, scalar_to_db(effective_volume_locked(d)));
            case kAudioLevelControlPropertyDecibelRange: {
                AudioValueRange r = { SR_MIN_DB, 0.0 };
                PUT(AudioValueRange, r);
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels:
                PUT(Float32, scalar_to_db(clampf(*(Float32 *)outData, 0.0f, 1.0f)));
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                PUT(Float32, db_to_scalar(*(Float32 *)outData));
            default: break;
        }
    } else if (a->mSelector == kAudioBooleanControlPropertyValue) {
        PUT(UInt32, effective_mute_locked(d) ? 1u : 0u);
    }
    return kAudioHardwareUnknownPropertyError;
}

/* gLock held. outData == NULL: size query only. */
static OSStatus prop_get(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                         UInt32 inSize, UInt32 *outSize, void *outData) {
    if (!a || !outSize) return kAudioHardwareIllegalOperationError;
    if (obj == kAudioObjectPlugInObject) return plugin_get(a, qSize, qData, inSize, outSize, outData);
    uint32_t sub;
    SRDevice *d = lookup_obj(obj, &sub);
    if (!d) return kAudioHardwareBadObjectError;
    switch (sub) {
        case SUB_DEVICE: return device_get(d, a, inSize, outSize, outData);
        case SUB_STREAM_IN: case SUB_STREAM_OUT: return stream_get(d, sub, a, inSize, outSize, outData);
        default: return control_get(d, sub, a, inSize, outSize, outData);
    }
}

/* ------------------------------------------------------------------ COM / driver interface */

static HRESULT SR_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG   SR_AddRef(void *inDriver);
static ULONG   SR_Release(void *inDriver);
static OSStatus SR_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SR_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus SR_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SR_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SR_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SR_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                    UInt64 inChangeAction, void *inChangeInfo);
static OSStatus SR_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                  UInt64 inChangeAction, void *inChangeInfo);
static Boolean  SR_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                               const AudioObjectPropertyAddress *inAddress);
static OSStatus SR_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus SR_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 *outDataSize);
static OSStatus SR_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                   const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SR_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                   const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus SR_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SR_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SR_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus SR_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus SR_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus SR_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                 UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus SR_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    SR_QueryInterface, SR_AddRef, SR_Release,
    SR_Initialize, SR_CreateDevice, SR_DestroyDevice,
    SR_AddDeviceClient, SR_RemoveDeviceClient,
    SR_PerformDeviceConfigurationChange, SR_AbortDeviceConfigurationChange,
    SR_HasProperty, SR_IsPropertySettable, SR_GetPropertyDataSize, SR_GetPropertyData, SR_SetPropertyData,
    SR_StartIO, SR_StopIO, SR_GetZeroTimeStamp,
    SR_WillDoIOOperation, SR_BeginIOOperation, SR_DoIOOperation, SR_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

__attribute__((visibility("default")))
void *SR_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void *SR_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (inRequestedTypeUUID && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT SR_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (!req) return kAudioHardwareIllegalOperationError;
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1u);
        *outInterface = gDriverRef;
        r = S_OK;
    }
    CFRelease(req);
    return r;
}

static ULONG SR_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1u) + 1u;
}

static ULONG SR_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    uint32_t cur = atomic_load(&gRefCount);
    while (cur > 0 && !atomic_compare_exchange_weak(&gRefCount, &cur, cur - 1u)) {}
    return cur > 0 ? cur - 1u : 0u;
}

static void initial_reload_f(void *ctx) { (void)ctx; reload_devices(); }

static OSStatus SR_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    gLog = os_log_create(SR_BUNDLE_ID, "driver");

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksPerSecond = 1e9 * (double)tb.denom / (double)tb.numer;
    gFreshTicks = (uint64_t)(0.1 * gTicksPerSecond);

    gQueue = dispatch_queue_create("io.soundrouter.driver.maintenance", DISPATCH_QUEUE_SERIAL);
    dispatch_sync_f(gQueue, NULL, initial_reload_f);   /* notifications suppressed: not initialized yet */
    atomic_store(&gInitialized, 1);

    uint32_t st = notify_register_dispatch(SR_NOTIFY_DEVICES_CHANGED, &gNotifyToken, gQueue, ^(int token) {
        (void)token;
        reload_devices();
    });
    if (st != NOTIFY_STATUS_OK) os_log_error(gLog, "notify_register_dispatch failed: %u (mtime poll only)", st);

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    if (gTimer) {
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)SR_TICK_MS * NSEC_PER_MSEC),
                                  (uint64_t)SR_TICK_MS * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler_f(gTimer, tick_f);
        dispatch_resume(gTimer);
    }
    os_log_info(gLog, "SoundRouter driver initialized");
    return kAudioHardwareNoError;
}

static OSStatus SR_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SR_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SR_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus SR_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus SR_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                    UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inChangeAction != SR_CHANGE_APPLY_PENDING) return kAudioHardwareNoError;
    pthread_mutex_lock(&gLock);
    uint32_t sub = 0;
    SRDevice *d = lookup_io(inDeviceObjectID, &sub);
    if (d && sub == SUB_DEVICE) {
        int changed = 0;
        if (d->pendingChannels && d->pendingChannels != d->channels) {
            if (d->loop) {
                SRShmHeader *nl = alloc_loop_block(d->pendingChannels, d->pendingRate ? d->pendingRate : d->sampleRate);
                if (nl) { retire_locked(d, d->loop, 0); d->loop = nl; d->channels = d->pendingChannels; changed = 1; }
            } else {
                d->channels = d->pendingChannels;
                changed = 1;
            }
        }
        if (d->pendingRate && d->pendingRate != d->sampleRate) {
            d->sampleRate = d->pendingRate;
            if (d->loop) d->loop->sampleRate = d->sampleRate;
            changed = 1;
        }
        d->pendingChannels = 0;
        d->pendingRate = 0;
        if (changed) {
            os_log_info(gLog, "device %{public}s reconfigured: ch %u rate %.0f", d->desc.id, d->channels, d->sampleRate);
            publish_state_locked(d, 1);
            refresh_mapping_locked(d);
            reap_locked(d);
        }
    }
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus SR_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                  UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static Boolean SR_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress) return false;
    UInt32 size = 0;
    pthread_mutex_lock(&gLock);
    OSStatus st = prop_get(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    pthread_mutex_unlock(&gLock);
    return st == kAudioHardwareNoError;
}

static OSStatus SR_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outIsSettable) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    pthread_mutex_lock(&gLock);
    OSStatus st = prop_get(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    uint32_t sub = 0;
    SRDevice *d = inObjectID == kAudioObjectPlugInObject ? NULL : lookup_obj(inObjectID, &sub);
    pthread_mutex_unlock(&gLock);
    if (st != kAudioHardwareNoError) return st;
    Boolean s = false;
    if (d) {
        AudioObjectPropertySelector sel = inAddress->mSelector;
        switch (sub) {
            case SUB_DEVICE: s = sel == kAudioDevicePropertyNominalSampleRate; break;
            case SUB_STREAM_IN: case SUB_STREAM_OUT:
                s = sel == kAudioStreamPropertyIsActive || sel == kAudioStreamPropertyVirtualFormat
                 || sel == kAudioStreamPropertyPhysicalFormat;
                break;
            case SUB_VOL_IN: case SUB_VOL_OUT:
                s = sel == kAudioLevelControlPropertyScalarValue || sel == kAudioLevelControlPropertyDecibelValue;
                break;
            case SUB_MUTE_IN: case SUB_MUTE_OUT: s = sel == kAudioBooleanControlPropertyValue; break;
        }
    }
    *outIsSettable = s;
    return kAudioHardwareNoError;
}

static OSStatus SR_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    OSStatus st = prop_get(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
    pthread_mutex_unlock(&gLock);
    return st;
}

static OSStatus SR_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                   const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!outData) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gLock);
    OSStatus st = prop_get(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    pthread_mutex_unlock(&gLock);
    return st;
}

/* gLock held. Validates a client rate change and stores it as pending; returns 1 if a
 * configuration change must be requested. */
static int request_rate_locked(SRDevice *d, double rate, OSStatus *err) {
    if (!sr_rate_supported(rate)) { *err = kAudioDeviceUnsupportedFormatError; return 0; }
    *err = kAudioHardwareNoError;
    double target = d->pendingRate ? d->pendingRate : d->sampleRate;
    if (rate == target) return 0;
    d->pendingRate = rate;
    if (wmap(d))
        atomic_store_explicit(&d->map->requestedSampleRateBits, sr_double_to_bits(rate), memory_order_release);
    os_log_info(gLog, "client requested rate %.0f on %{public}s", rate, d->desc.id);
    return 1;
}

static void host_control_set_locked(SRDevice *d, float vol, int mute, uint64_t now) {
    d->volume = vol;
    d->mute = mute;
    d->hostPending = 1;
    d->hostPendingAt = now;
    d->hostVolume = vol;
    d->hostMute = mute;
    SRShmHeader *h = wmap(d);
    if (h) {
        atomic_store_explicit(&h->hostVolumeBits, sr_float_to_bits(vol), memory_order_relaxed);
        atomic_store_explicit(&h->hostMuted, mute ? 1u : 0u, memory_order_relaxed);
        atomic_fetch_add_explicit(&h->hostControlSeq, 1u, memory_order_release);
    }
}

static OSStatus SR_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                   const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !inData) return kAudioHardwareIllegalOperationError;
    if (inObjectID == kAudioObjectPlugInObject) return kAudioHardwareUnknownPropertyError;

    SRNotes *notes = calloc(1, sizeof *notes);
    if (!notes) return kAudioHardwareUnspecifiedError;
    OSStatus st = kAudioHardwareUnknownPropertyError;
    AudioObjectID requestFor = kAudioObjectUnknown;
    AudioObjectPropertySelector sel = inAddress->mSelector;

    pthread_mutex_lock(&gLock);
    uint32_t sub = 0;
    SRDevice *d = lookup_obj(inObjectID, &sub);
    if (!d) {
        st = kAudioHardwareBadObjectError;
    } else if (sub == SUB_DEVICE && sel == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) st = kAudioHardwareBadPropertySizeError;
        else if (request_rate_locked(d, *(const Float64 *)inData, &st)) requestFor = d->idDevice;
    } else if ((sub == SUB_STREAM_IN || sub == SUB_STREAM_OUT) && sel == kAudioStreamPropertyIsActive) {
        if (inDataSize < sizeof(UInt32)) st = kAudioHardwareBadPropertySizeError;
        else {
            if (sub == SUB_STREAM_IN) d->streamInActive = *(const UInt32 *)inData != 0;
            else d->streamOutActive = *(const UInt32 *)inData != 0;
            notes_add(notes, inObjectID, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal);
            st = kAudioHardwareNoError;
        }
    } else if ((sub == SUB_STREAM_IN || sub == SUB_STREAM_OUT)
               && (sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) st = kAudioHardwareBadPropertySizeError;
        else {
            const AudioStreamBasicDescription *f = inData;
            AudioStreamBasicDescription ours;
            fill_asbd(&ours, f->mSampleRate, d->channels);
            if (f->mFormatID != ours.mFormatID || f->mFormatFlags != ours.mFormatFlags
                || f->mBitsPerChannel != ours.mBitsPerChannel || f->mChannelsPerFrame != ours.mChannelsPerFrame
                || f->mBytesPerFrame != ours.mBytesPerFrame || f->mFramesPerPacket != 1)
                st = kAudioDeviceUnsupportedFormatError;
            else if (request_rate_locked(d, f->mSampleRate, &st))
                requestFor = d->idDevice;
        }
    } else if ((sub == SUB_VOL_IN || sub == SUB_VOL_OUT)
               && (sel == kAudioLevelControlPropertyScalarValue || sel == kAudioLevelControlPropertyDecibelValue)) {
        if (inDataSize < sizeof(Float32)) st = kAudioHardwareBadPropertySizeError;
        else {
            Float32 v = *(const Float32 *)inData;
            v = sel == kAudioLevelControlPropertyScalarValue ? clampf(v, 0.0f, 1.0f) : db_to_scalar(clampf(v, SR_MIN_DB, 0.0f));
            if (v != v) v = 0.0f; /* NaN */
            if (v != d->volume || d->hostPending == 0) {
                host_control_set_locked(d, v, d->mute, mach_absolute_time());
                notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_IN), kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
                notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_IN), kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal);
                if (d->passThru) {
                    notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_OUT), kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
                    notes_add(notes, mkid(d->gen, d->slot, SUB_VOL_OUT), kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal);
                }
            }
            st = kAudioHardwareNoError;
        }
    } else if ((sub == SUB_MUTE_IN || sub == SUB_MUTE_OUT) && sel == kAudioBooleanControlPropertyValue) {
        if (inDataSize < sizeof(UInt32)) st = kAudioHardwareBadPropertySizeError;
        else {
            int m = *(const UInt32 *)inData != 0;
            host_control_set_locked(d, d->volume, m, mach_absolute_time());
            notes_add(notes, mkid(d->gen, d->slot, SUB_MUTE_IN), kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
            if (d->passThru)
                notes_add(notes, mkid(d->gen, d->slot, SUB_MUTE_OUT), kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
            st = kAudioHardwareNoError;
        }
    } else {
        UInt32 size = 0;
        OSStatus has = prop_get(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
        st = has == kAudioHardwareNoError ? kAudioHardwareUnsupportedOperationError : has;
    }
    pthread_mutex_unlock(&gLock);

    notes_flush(notes);
    free(notes);
    if (requestFor != kAudioObjectUnknown && gQueue)
        dispatch_async_f(gQueue, (void *)(uintptr_t)requestFor, request_config_f);
    return st;
}

static OSStatus SR_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    OSStatus st = kAudioHardwareNoError;
    pthread_mutex_lock(&gLock);
    uint32_t sub = 0;
    SRDevice *d = lookup_io(inDeviceObjectID, &sub);
    if (!d || sub != SUB_DEVICE || d->removed) {
        st = kAudioHardwareBadObjectError;
    } else {
        uint32_t c = atomic_fetch_add(&d->ioClients, 1u) + 1u;
        if (c == 1) {
            refresh_mapping_locked(d);
            publish_state_locked(d, 1);
        }
        if (wmap(d)) atomic_store(&d->map->driverIORunning, c);
    }
    pthread_mutex_unlock(&gLock);
    return st;
}

static OSStatus SR_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    OSStatus st = kAudioHardwareNoError;
    pthread_mutex_lock(&gLock);
    uint32_t sub = 0;
    SRDevice *d = lookup_io(inDeviceObjectID, &sub);   /* removed devices included */
    if (!d || sub != SUB_DEVICE) {
        st = kAudioHardwareBadObjectError;
    } else {
        uint32_t c = atomic_load(&d->ioClients);
        if (c > 0) { c--; atomic_store(&d->ioClients, c); }
        if (!d->removed && wmap(d)) atomic_store(&d->map->driverIORunning, c);
    }
    pthread_mutex_unlock(&gLock);
    return st;
}

/* ------------------------------------------------------------------ IO path: lock-free, no syscalls */

static OSStatus SR_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inClientID;
    SRDevice *d = lookup_io(inDeviceObjectID, NULL);
    if (!d) return kAudioHardwareBadObjectError;
    const SRIOState *s = atomic_load_explicit(&d->io, memory_order_acquire);
    if (!s) return kAudioHardwareBadObjectError;
    uint64_t now = mach_absolute_time();
    double elapsed = now > s->anchor ? (double)(now - s->anchor) : 0.0;
    double cycles = floor(elapsed / s->ticksPerRing);
    *outSampleTime = cycles * (double)SR_RING_FRAMES;
    *outHostTime = s->anchor + (UInt64)(cycles * s->ticksPerRing);
    *outSeed = s->seed;
    return kAudioHardwareNoError;
}

static OSStatus SR_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean will = inOperationID == kAudioServerPlugInIOOperationReadInput
                || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus SR_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus SR_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                 UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inClientID; (void)ioSecondaryBuffer;
    SRDevice *d = lookup_io(inDeviceObjectID, NULL);
    if (!d || !ioMainBuffer || !inIOCycleInfo) return kAudioHardwareNoError; /* never fail IO */
    const SRIOState *s = atomic_load_explicit(&d->io, memory_order_acquire);
    if (!s) return kAudioHardwareNoError;
    uint32_t streamSub = inStreamObjectID & 0xFu;
    uint32_t frames = inIOBufferFrameSize;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && streamSub == SUB_STREAM_IN) {
        float *out = ioMainBuffer;
        SRShmHeader *h = s->hdr;
        if (!h) {
            memset(out, 0, (size_t)frames * s->channels * sizeof(float));
            return kAudioHardwareNoError;
        }
        float *base = (float *)((uint8_t *)h + sizeof(SRShmHeader));
        int64_t start = (int64_t)floor(inIOCycleInfo->mInputTime.mSampleTime);
        const float *planes;
        int64_t wf;
        if (s->loopback) {
            planes = base + (size_t)s->channels * SR_RING_FRAMES;
            wf = atomic_load_explicit(&h->passThruWriteFrame, memory_order_acquire);
        } else {
            planes = base;
            wf = atomic_load_explicit(&h->mixWriteFrame, memory_order_acquire);
        }
        uint32_t valid = sr_ring_read(planes, s->channels, wf, start, frames, out, s->channels, !SR_NONINTERLEAVED);
        if (!s->loopback && !s->readOnly && valid < frames && engine_fresh(h, mach_absolute_time()))
            atomic_fetch_add_explicit(&h->underrunCount, (uint64_t)(frames - valid), memory_order_relaxed);
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix && streamSub == SUB_STREAM_OUT) {
        SRShmHeader *h = s->hdr;
        if (!h || s->readOnly) return kAudioHardwareNoError;
        float *pt = (float *)((uint8_t *)h + sizeof(SRShmHeader)) + (size_t)s->channels * SR_RING_FRAMES;
        int64_t start = (int64_t)floor(inIOCycleInfo->mOutputTime.mSampleTime);
        sr_ring_write(pt, s->channels, start, frames, ioMainBuffer, s->channels, !SR_NONINTERLEAVED);
        sr_atomic_max_i64(&h->passThruWriteFrame, start + (int64_t)frames);
    }
    return kAudioHardwareNoError;
}

static OSStatus SR_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
