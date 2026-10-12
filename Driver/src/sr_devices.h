// sr_devices.h — pure (no CoreAudio) helpers for the SoundRouter HAL driver:
//   * a minimal, robust JSON parser specialised for devices.json (see sr_shm.h)
//   * the device-list diff used to add / remove / reconfigure devices at runtime
// Only depends on libc. Unit-tested by Driver/tests without coreaudiod.

#ifndef SR_DEVICES_H
#define SR_DEVICES_H

#include <stdint.h>
#include <stddef.h>

#define SR_DEVDESC_ID_MAX     64    /* bytes incl. NUL */
#define SR_DEVDESC_NAME_MAX   128   /* bytes incl. NUL (UTF-8, never cut mid code point) */
#define SR_MAX_DEVICES        64    /* max devices accepted from devices.json */
#define SR_DEFAULT_RATE       48000.0
#define SR_DEFAULT_CHANNELS   2u
#define SR_DEFAULT_NAME       "SoundRouter"

typedef struct SRDevDesc {
    char     id[SR_DEVDESC_ID_MAX];     /* UID, normalised to uppercase */
    char     name[SR_DEVDESC_NAME_MAX];
    uint32_t channels;                  /* 1..SR_MAX_CHANNELS */
    double   sampleRate;                /* one of sr_supported_rates */
    int      passThru;                  /* 0/1 */
} SRDevDesc;

extern const double sr_supported_rates[6];
enum { SR_SUPPORTED_RATE_COUNT = 6 };
int sr_rate_supported(double rate);

/* Parse devices.json.
 * Returns 0 on success (*outCount = accepted devices; invalid entries are skipped,
 * duplicates by id keep the first one, a missing "devices" key yields 0 devices),
 * -1 on a JSON syntax error or a non-object top level (caller keeps its current list). */
int sr_devices_json_parse(const char *json, size_t len,
                          SRDevDesc *out, uint32_t maxOut, uint32_t *outCount);

/* Device-list diff. */
typedef enum SRDiffKind {
    SR_DIFF_REMOVE   = 1,   /* oldIndex valid */
    SR_DIFF_RECREATE = 2,   /* old+new valid: passThru changed -> remove + re-add */
    SR_DIFF_UPDATE   = 3,   /* old+new valid: see changes (name / channels / rate) */
    SR_DIFF_ADD      = 4    /* newIndex valid */
} SRDiffKind;

enum {
    SR_CHG_NAME     = 1u << 0,
    SR_CHG_CHANNELS = 1u << 1,
    SR_CHG_RATE     = 1u << 2,
    SR_CHG_PASSTHRU = 1u << 3
};

typedef struct SRDiffOp {
    SRDiffKind kind;
    int32_t    oldIndex;    /* -1 if none */
    int32_t    newIndex;    /* -1 if none */
    uint32_t   changes;     /* SR_CHG_* bitmask */
} SRDiffOp;

/* Compare two device lists (matched by id). Unchanged devices produce no op.
 * Ops are ordered: all REMOVE, then RECREATE, then UPDATE, then ADD.
 * maxOps >= nOld + nNew is always sufficient. Returns the number of ops written. */
uint32_t sr_devlist_diff(const SRDevDesc *oldList, uint32_t nOld,
                         const SRDevDesc *newList, uint32_t nNew,
                         SRDiffOp *ops, uint32_t maxOps);

#endif /* SR_DEVICES_H */
