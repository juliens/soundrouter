// In-process integration harness: links sr_driver.c (built with -DSR_TESTING) and drives it
// through the real AudioServerPlugInDriverInterface with a fake host, playing the engine's
// role on a real POSIX shm segment. No coreaudiod involved. `make harness` in Driver/.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <notify.h>

#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "sr_shm.h"

void *SR_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

static char gJsonPath[1024], gJ1Path[1024];
const char *sr_test_json_path(void) { return gJsonPath; }
const char *sr_test_j1_path(void) { return gJ1Path; }

static int gFails, gChecks;
#define CHECK(cond) do { gChecks++; if (!(cond)) { gFails++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

/* ------------------------------------------------------------------ fake host */
static int gPropChanges, gDeviceListChanges;
static AudioObjectID gCfgReq[16];
static int gNCfgReq;

static OSStatus H_PropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *a) {
    (void)h;
    for (UInt32 i = 0; i < n; ++i) {
        gPropChanges++;
        if (obj == kAudioObjectPlugInObject && a[i].mSelector == kAudioPlugInPropertyDeviceList) gDeviceListChanges++;
    }
    return 0;
}
static OSStatus H_Copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *o) { (void)h; (void)k; *o = NULL; return 0; }
static OSStatus H_Write(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h; (void)k; (void)d; return 0; }
static OSStatus H_Delete(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus H_RequestCfg(AudioServerPlugInHostRef h, AudioObjectID dev, UInt64 act, void *info) {
    (void)h; (void)act; (void)info;
    if (gNCfgReq < 16) gCfgReq[gNCfgReq++] = dev;
    return 0;
}
static AudioServerPlugInHostInterface gHostIf = { H_PropertiesChanged, H_Copy, H_Write, H_Delete, H_RequestCfg };

/* ------------------------------------------------------------------ helpers */
static AudioServerPlugInDriverRef D;
#define DRV (*D)

static UInt32 get_u32(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { s, sc, kAudioObjectPropertyElementMain };
    UInt32 v = 0xDEADBEEF, sz = 0;
    OSStatus st = DRV->GetPropertyData(D, o, 0, &a, 0, NULL, sizeof v, &sz, &v);
    return st == 0 ? v : 0xDEADBEEF;
}
static Float64 get_f64(AudioObjectID o, AudioObjectPropertySelector s) {
    AudioObjectPropertyAddress a = { s, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 v = -1; UInt32 sz = 0;
    DRV->GetPropertyData(D, o, 0, &a, 0, NULL, sizeof v, &sz, &v);
    return v;
}
static Float32 get_f32(AudioObjectID o, AudioObjectPropertySelector s) {
    AudioObjectPropertyAddress a = { s, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float32 v = -1; UInt32 sz = 0;
    DRV->GetPropertyData(D, o, 0, &a, 0, NULL, sizeof v, &sz, &v);
    return v;
}
static UInt32 get_ids(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc, AudioObjectID *ids, UInt32 max) {
    AudioObjectPropertyAddress a = { s, sc, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (DRV->GetPropertyDataSize(D, o, 0, &a, 0, NULL, &sz) != 0) return 0;
    if (sz > max * sizeof(AudioObjectID)) sz = max * sizeof(AudioObjectID);
    if (DRV->GetPropertyData(D, o, 0, &a, 0, NULL, sz, &sz, ids) != 0) return 0;
    return sz / sizeof(AudioObjectID);
}
static int get_str(AudioObjectID o, AudioObjectPropertySelector s, char *buf, size_t cap) {
    AudioObjectPropertyAddress a = { s, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef v = NULL; UInt32 sz = 0;
    if (DRV->GetPropertyData(D, o, 0, &a, 0, NULL, sizeof v, &sz, &v) != 0 || !v) return -1;
    int ok = CFStringGetCString(v, buf, (CFIndex)cap, kCFStringEncodingUTF8);
    CFRelease(v);
    return ok ? 0 : -1;
}
static AudioObjectID uid_to_dev(const char *uid) {
    AudioObjectPropertyAddress a = { kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID id = 0; UInt32 sz = 0;
    DRV->GetPropertyData(D, kAudioObjectPlugInObject, 0, &a, sizeof s, &s, sizeof id, &sz, &id);
    CFRelease(s);
    return id;
}
static OSStatus set_prop(AudioObjectID o, AudioObjectPropertySelector s, UInt32 size, const void *data) {
    AudioObjectPropertyAddress a = { s, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    return DRV->SetPropertyData(D, o, 0, &a, 0, NULL, size, data);
}
static void write_file(const char *path, const char *text) {
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    fputs(text, f);
    fclose(f);
    rename(tmp, path);
}
static void msleep(int ms) { usleep((useconds_t)ms * 1000); }

#define UA "A1B2C3D4-0000-4000-8000-5352484E5431"   /* harness-only UIDs */
#define UB "B1B2C3D4-0000-4000-8000-5352484E5432"
#define J1 "53524A31-0000-4000-8000-000000000001"

int main(void) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp) tmp = "/tmp";
    snprintf(gJsonPath, sizeof gJsonPath, "%s/sr_harness_devices.json", tmp);
    snprintf(gJ1Path, sizeof gJ1Path, "%s/sr_harness_j1", tmp);
    unlink(gJsonPath); unlink(gJ1Path);

    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double tps = 1e9 * tb.denom / tb.numer;

    /* ---- engine role: create the shm segment for UA (2 ch, 48 kHz, pass-thru) */
    char shmName[SR_SHM_NAME_MAX + 1];
    sr_shm_name(UA, shmName);
    shm_unlink(shmName);
    SRShmHeader *h = NULL;
    size_t shmLen = sr_shm_size(2);
    int fd = shm_open(shmName, O_RDWR | O_CREAT | O_EXCL, 0666);
    if (fd >= 0 && ftruncate(fd, (off_t)shmLen) == 0) {
        h = mmap(NULL, shmLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (h == MAP_FAILED) h = NULL;
    }
    if (fd >= 0) close(fd);
    if (!h) { fprintf(stderr, "shm_open/mmap failed (sandbox?) — cannot run harness\n"); return 2; }
    h->magic = SR_SHM_MAGIC; h->version = SR_SHM_VERSION; h->channelCount = 2;
    h->ringFrames = SR_RING_FRAMES; h->sampleRate = 48000; h->hasPassThru = 1;
    h->anchorHostTime = mach_absolute_time() - (uint64_t)(tps * 3.0);   /* engine started 3 s ago */
    atomic_store(&h->volumeBits, sr_float_to_bits(0.5f));
    atomic_store(&h->engineHeartbeat, mach_absolute_time());

    write_file(gJsonPath,
        "{\"schemaVersion\":1,\"devices\":["
        "{\"id\":\"" UA "\",\"name\":\"Mix A\",\"channels\":2,\"sampleRate\":48000,\"passThru\":true},"
        "{\"id\":\"" UB "\",\"name\":\"Mix B\",\"channels\":4,\"sampleRate\":96000,\"passThru\":false}]}");

    /* ---- load the plug-in */
    CFUUIDRef type = CFUUIDCreateFromString(NULL, CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
    void *iface = SR_Create(NULL, type);
    CHECK(iface != NULL);
    CHECK(SR_Create(NULL, CFUUIDCreateFromString(NULL, CFSTR("00000000-0000-0000-0000-000000000000"))) == NULL);
    D = iface;
    void *qi = NULL;
    CHECK(DRV->QueryInterface(D, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &qi) == 0 && qi == D);
    DRV->Release(D);
    AudioServerPlugInHostInterface *hostPtr = &gHostIf;
    CHECK(DRV->Initialize(D, hostPtr) == 0);

    /* ---- plug-in / device topology */
    AudioObjectID ids[16];
    CHECK(get_ids(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, 16) == 2);
    AudioObjectID da = uid_to_dev(UA), db = uid_to_dev(UB);
    CHECK(da != 0 && db != 0 && da != db);
    CHECK(uid_to_dev("nope") == kAudioObjectUnknown);
    char buf[256];
    CHECK(get_str(da, kAudioObjectPropertyName, buf, sizeof buf) == 0 && strcmp(buf, "Mix A") == 0);
    CHECK(get_str(da, kAudioDevicePropertyDeviceUID, buf, sizeof buf) == 0 && strcmp(buf, UA) == 0);
    CHECK(get_str(da, kAudioObjectPropertyManufacturer, buf, sizeof buf) == 0 && strcmp(buf, "SoundRouter") == 0);
    CHECK(get_u32(da, kAudioObjectPropertyClass, 0) == kAudioDeviceClassID);
    CHECK(get_u32(da, kAudioDevicePropertyTransportType, 0) == kAudioDeviceTransportTypeVirtual);
    CHECK(get_u32(da, kAudioDevicePropertyZeroTimeStampPeriod, 0) == SR_RING_FRAMES);
    CHECK(get_u32(da, kAudioDevicePropertyIsHidden, 0) == 0);
    CHECK(get_u32(da, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 1);
    CHECK(get_u32(db, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0);
    CHECK(get_u32(db, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1);
    CHECK(get_f64(db, kAudioDevicePropertyNominalSampleRate) == 96000.0);
    CHECK(get_ids(da, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, ids, 16) == 1);
    CHECK(get_ids(da, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, ids, 16) == 1);
    AudioObjectID aOut = ids[0];
    CHECK(get_ids(db, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, ids, 16) == 0);
    CHECK(get_ids(db, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal, ids, 16) == 1);
    AudioObjectID bIn = ids[0];
    CHECK(get_ids(da, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, ids, 16) == 1);
    AudioObjectID aIn = ids[0];
    CHECK(get_u32(aIn, kAudioStreamPropertyDirection, 0) == 1 && get_u32(aOut, kAudioStreamPropertyDirection, 0) == 0);
    {
        AudioObjectPropertyAddress a = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioStreamBasicDescription f; UInt32 sz = 0;
        CHECK(DRV->GetPropertyData(D, bIn, 0, &a, 0, NULL, sizeof f, &sz, &f) == 0);
        CHECK(f.mChannelsPerFrame == 4 && f.mSampleRate == 96000 && f.mBitsPerChannel == 32 && (f.mFormatFlags & kAudioFormatFlagIsFloat));
        a.mSelector = kAudioStreamPropertyAvailablePhysicalFormats;
        CHECK(DRV->GetPropertyDataSize(D, bIn, 0, &a, 0, NULL, &sz) == 0 && sz == 6 * sizeof(AudioStreamRangedDescription));
    }
    AudioObjectID ctl[8];
    UInt32 nctl = get_ids(da, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, ctl, 8);
    CHECK(nctl == 4);
    CHECK(get_ids(db, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, ids, 8) == 2);
    AudioObjectID volA = ctl[0], muteA = ctl[1];
    CHECK(get_u32(volA, kAudioObjectPropertyClass, 0) == kAudioVolumeControlClassID);
    CHECK(get_u32(muteA, kAudioObjectPropertyClass, 0) == kAudioMuteControlClassID);
    {
        AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Boolean s = false;
        CHECK(DRV->IsPropertySettable(D, da, 0, &a, &s) == 0 && s);
        CHECK(DRV->HasProperty(D, da, 0, &a));
        a.mSelector = 'zzzz';
        CHECK(!DRV->HasProperty(D, da, 0, &a));
        CHECK(!DRV->HasProperty(D, 0x7FFFFFF0u, 0, &a));
    }

    /* ---- controls follow shm (engine) values */
    CHECK(get_f32(volA, kAudioLevelControlPropertyScalarValue) == 0.5f);
    Float32 v = 0.25f;
    uint32_t seq0 = atomic_load(&h->hostControlSeq);
    CHECK(set_prop(volA, kAudioLevelControlPropertyScalarValue, sizeof v, &v) == 0);
    CHECK(atomic_load(&h->hostControlSeq) == seq0 + 1);
    CHECK(sr_bits_to_float(atomic_load(&h->hostVolumeBits)) == 0.25f);
    CHECK(get_f32(volA, kAudioLevelControlPropertyScalarValue) == 0.25f);   /* host value while pending */
    UInt32 one = 1;
    CHECK(set_prop(muteA, kAudioBooleanControlPropertyValue, sizeof one, &one) == 0 && atomic_load(&h->hostMuted) == 1);
    /* engine mirrors it back */
    atomic_store(&h->volumeBits, sr_float_to_bits(0.25f));
    atomic_store(&h->muted, 1);
    for (int i = 0; i < 8; ++i) { atomic_store(&h->engineHeartbeat, mach_absolute_time()); msleep(50); }
    /* engine changes volume on its own -> PropertiesChanged */
    int pc0 = gPropChanges;
    atomic_store(&h->volumeBits, sr_float_to_bits(0.75f));
    for (int i = 0; i < 10; ++i) { atomic_store(&h->engineHeartbeat, mach_absolute_time()); msleep(50); }
    CHECK(gPropChanges > pc0);
    CHECK(get_f32(volA, kAudioLevelControlPropertyScalarValue) == 0.75f);
    CHECK(get_u32(muteA, kAudioBooleanControlPropertyValue, 0) == 1);

    /* ---- IO: clock anchored on the engine anchor */
    CHECK(atomic_load(&h->driverMapped) == 1);
    CHECK(DRV->StartIO(D, da, 1) == 0);
    CHECK(atomic_load(&h->driverIORunning) == 1);
    CHECK(get_u32(da, kAudioDevicePropertyDeviceIsRunning, 0) == 1);
    Float64 st; UInt64 ht, seed;
    CHECK(DRV->GetZeroTimeStamp(D, da, 1, &st, &ht, &seed) == 0);
    uint64_t now = mach_absolute_time();
    double engineNow = (double)(now - h->anchorHostTime) * 48000.0 / tps;   /* engine's sample time */
    CHECK(fmod(st, SR_RING_FRAMES) == 0.0 && st <= engineNow && engineNow - st < SR_RING_FRAMES + 1);
    CHECK(ht <= now && fabs(((double)(ht - h->anchorHostTime)) * 48000.0 / tps - st) < 1.0);

    /* engine writes 512 frames of mix at sample S0 */
    int64_t S0 = (int64_t)engineNow - 1024;
    float *mix0 = (float *)((uint8_t *)h + sizeof(SRShmHeader));
    for (int k = 0; k < 512; ++k) {
        mix0[((uint64_t)(S0 + k)) & SR_RING_MASK] = (float)k;                  /* L */
        mix0[SR_RING_FRAMES + (((uint64_t)(S0 + k)) & SR_RING_MASK)] = -(float)k; /* R */
    }
    atomic_store(&h->mixWriteFrame, S0 + 512);
    atomic_store(&h->engineHeartbeat, mach_absolute_time());
    AudioServerPlugInIOCycleInfo cyc; memset(&cyc, 0, sizeof cyc);
    float io[1024 * 2];
    cyc.mInputTime.mSampleTime = (Float64)S0 + 256;
    uint64_t under0 = atomic_load(&h->underrunCount);
    Boolean will = 0, inplace = 0;
    CHECK(DRV->WillDoIOOperation(D, da, 1, kAudioServerPlugInIOOperationReadInput, &will, &inplace) == 0 && will && inplace);
    CHECK(DRV->DoIOOperation(D, da, aIn, 1, kAudioServerPlugInIOOperationReadInput, 512, &cyc, io, NULL) == 0);
    int okread = 1;
    for (int k = 0; k < 512; ++k) {
        float wl = k < 256 ? (float)(k + 256) : 0.0f;
        if (io[2 * k] != wl || io[2 * k + 1] != -wl) okread = 0;
    }
    CHECK(okread);
    CHECK(atomic_load(&h->underrunCount) == under0 + 256);   /* engine alive, 256 frames missing */

    /* pass-thru write */
    for (int k = 0; k < 256; ++k) { io[2 * k] = 0.5f + (float)k; io[2 * k + 1] = -0.5f; }
    cyc.mOutputTime.mSampleTime = (Float64)S0 + 4096;
    CHECK(DRV->DoIOOperation(D, da, aOut, 1, kAudioServerPlugInIOOperationWriteMix, 256, &cyc, io, NULL) == 0);
    CHECK(atomic_load(&h->passThruWriteFrame) == S0 + 4096 + 256);
    float *pt0 = mix0 + 2 * SR_RING_FRAMES;
    CHECK(pt0[((uint64_t)(S0 + 4096 + 10)) & SR_RING_MASK] == 10.5f);
    CHECK(pt0[SR_RING_FRAMES + (((uint64_t)(S0 + 4096 + 10)) & SR_RING_MASK)] == -0.5f);

    /* device without segment: silence, no error */
    CHECK(DRV->StartIO(D, db, 1) == 0);
    memset(io, 0x55, sizeof io);
    CHECK(DRV->DoIOOperation(D, db, bIn, 1, kAudioServerPlugInIOOperationReadInput, 256, &cyc, io, NULL) == 0);
    CHECK(io[0] == 0.0f && io[256 * 4 - 1] == 0.0f);
    CHECK(DRV->GetZeroTimeStamp(D, db, 1, &st, &ht, &seed) == 0);
    CHECK(DRV->StopIO(D, db, 1) == 0);

    /* ---- client sample-rate change */
    Float64 r = 12345;
    CHECK(set_prop(da, kAudioDevicePropertyNominalSampleRate, sizeof r, &r) != 0);
    r = 96000;
    gNCfgReq = 0;
    CHECK(set_prop(da, kAudioDevicePropertyNominalSampleRate, sizeof r, &r) == 0);
    CHECK(sr_bits_to_double(atomic_load(&h->requestedSampleRateBits)) == 96000.0);
    msleep(100);
    CHECK(gNCfgReq == 1 && gCfgReq[0] == da);
    CHECK(DRV->StopIO(D, da, 1) == 0);
    CHECK(atomic_load(&h->driverIORunning) == 0);
    CHECK(DRV->PerformDeviceConfigurationChange(D, da, 1, NULL) == 0);
    CHECK(get_f64(da, kAudioDevicePropertyNominalSampleRate) == 96000.0);
    /* segment is 48 kHz -> silence now */
    CHECK(DRV->StartIO(D, da, 1) == 0);
    memset(io, 0x55, sizeof io);
    cyc.mInputTime.mSampleTime = (Float64)S0 + 256;
    DRV->DoIOOperation(D, da, aIn, 1, kAudioServerPlugInIOOperationReadInput, 128, &cyc, io, NULL);
    CHECK(io[0] == 0.0f && io[10] == 0.0f);
    CHECK(DRV->StopIO(D, da, 1) == 0);

    /* ---- dynamic reload: rename A, remove B, add a device with J1-less UID, via notify */
    gDeviceListChanges = 0;
    write_file(gJsonPath,
        "{\"schemaVersion\":1,\"devices\":["
        "{\"id\":\"" UA "\",\"name\":\"Mix A2\",\"channels\":2,\"sampleRate\":96000,\"passThru\":true}]}");
    notify_post(SR_NOTIFY_DEVICES_CHANGED);
    for (int i = 0; i < 40 && gDeviceListChanges == 0; ++i) msleep(100);   /* notify or 2 s mtime poll */
    CHECK(gDeviceListChanges > 0);
    CHECK(get_ids(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, 16) == 1);
    CHECK(uid_to_dev(UA) == da && uid_to_dev(UB) == 0);
    CHECK(get_str(da, kAudioObjectPropertyName, buf, sizeof buf) == 0 && strcmp(buf, "Mix A2") == 0);
    CHECK(get_u32(db, kAudioObjectPropertyClass, 0) == 0xDEADBEEF);   /* removed -> bad object */

    /* passThru toggle -> recreate with a new object ID, same UID */
    gDeviceListChanges = 0;
    write_file(gJsonPath,
        "{\"devices\":[{\"id\":\"" UA "\",\"name\":\"Mix A2\",\"channels\":2,\"sampleRate\":96000,\"passThru\":false}]}");
    notify_post(SR_NOTIFY_DEVICES_CHANGED);
    for (int i = 0; i < 40 && gDeviceListChanges == 0; ++i) msleep(100);
    AudioObjectID da2 = uid_to_dev(UA);
    CHECK(da2 != 0 && da2 != da);
    CHECK(get_ids(da2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, ids, 16) == 0);

    /* channel change -> RequestDeviceConfigurationChange */
    gNCfgReq = 0;
    write_file(gJsonPath,
        "{\"devices\":[{\"id\":\"" UA "\",\"name\":\"Mix A2\",\"channels\":6,\"sampleRate\":96000,\"passThru\":false}]}");
    notify_post(SR_NOTIFY_DEVICES_CHANGED);
    for (int i = 0; i < 40 && gNCfgReq == 0; ++i) msleep(100);
    CHECK(gNCfgReq == 1 && gCfgReq[0] == da2);
    CHECK(DRV->PerformDeviceConfigurationChange(D, da2, 1, NULL) == 0);
    get_ids(da2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, ids, 16);
    {
        AudioObjectPropertyAddress a = { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioStreamBasicDescription f; UInt32 sz = 0;
        CHECK(DRV->GetPropertyData(D, ids[0], 0, &a, 0, NULL, sizeof f, &sz, &f) == 0 && f.mChannelsPerFrame == 6);
    }

    /* garbage file keeps the current list */
    write_file(gJsonPath, "{\"devices\":[{");
    notify_post(SR_NOTIFY_DEVICES_CHANGED);
    msleep(2600);
    CHECK(uid_to_dev(UA) == da2);

    /* ---- J1: file missing + flag -> loopback device, bit exact */
    unlink(gJsonPath);
    write_file(gJ1Path, "1");
    gDeviceListChanges = 0;
    notify_post(SR_NOTIFY_DEVICES_CHANGED);
    for (int i = 0; i < 40 && uid_to_dev(J1) == 0; ++i) msleep(100);
    AudioObjectID dj = uid_to_dev(J1);
    CHECK(dj != 0 && uid_to_dev(UA) == 0);
    if (dj) {
        get_ids(dj, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, ids, 16);
        AudioObjectID jIn = ids[0];
        get_ids(dj, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, ids, 16);
        AudioObjectID jOut = ids[0];
        CHECK(DRV->StartIO(D, dj, 7) == 0);
        CHECK(DRV->GetZeroTimeStamp(D, dj, 7, &st, &ht, &seed) == 0);
        float src[480 * 2], dst[480 * 2];
        for (int k = 0; k < 960; ++k) src[k] = (float)rand() / (float)RAND_MAX * 2.0f - 1.0f;
        cyc.mOutputTime.mSampleTime = 1000;
        DRV->DoIOOperation(D, dj, jOut, 7, kAudioServerPlugInIOOperationWriteMix, 480, &cyc, src, NULL);
        cyc.mInputTime.mSampleTime = 1000;
        DRV->DoIOOperation(D, dj, jIn, 7, kAudioServerPlugInIOOperationReadInput, 480, &cyc, dst, NULL);
        CHECK(memcmp(src, dst, sizeof src) == 0);
        CHECK(DRV->StopIO(D, dj, 7) == 0);
    }
    /* no flag, no file -> nothing */
    unlink(gJ1Path);
    notify_post(SR_NOTIFY_DEVICES_CHANGED);
    for (int i = 0; i < 40 && uid_to_dev(J1) != 0; ++i) msleep(100);
    CHECK(get_ids(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, 16) == 0);

    msleep(5600);  /* removed devices reaped after the grace period (no crash) */

    munmap(h, shmLen);
    shm_unlink(shmName);
    printf("harness: %d/%d checks passed\n", gChecks - gFails, gChecks);
    return gFails ? 1 : 0;
}
