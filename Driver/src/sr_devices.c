// sr_devices.c — devices.json parser + device-list diff (pure C11, libc only).

#include "sr_devices.h"
#include "sr_shm.h"

#include <string.h>

const double sr_supported_rates[6] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };

int sr_rate_supported(double rate) {
    for (int i = 0; i < SR_SUPPORTED_RATE_COUNT; ++i)
        if (rate == sr_supported_rates[i]) return 1;
    return 0;
}

/* ------------------------------------------------------------------ JSON cursor */

#define SR_JSON_MAX_DEPTH 64

typedef struct {
    const char *p;
    const char *end;
    int depth;
} JCur;

static void j_ws(JCur *c) {
    while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++;
}

static int j_peek(JCur *c) {
    j_ws(c);
    return c->p < c->end ? (unsigned char)*c->p : -1;
}

static int j_expect(JCur *c, char ch) {
    if (j_peek(c) != (unsigned char)ch) return -1;
    c->p++;
    return 0;
}

static int j_literal(JCur *c, const char *lit) {
    size_t n = strlen(lit);
    if ((size_t)(c->end - c->p) < n || memcmp(c->p, lit, n) != 0) return -1;
    c->p += n;
    return 0;
}

/* Output buffer for decoded strings: never cuts a UTF-8 sequence. */
typedef struct {
    char  *buf;     /* may be NULL (skip) */
    size_t cap;     /* incl. NUL */
    size_t len;
    int    full;
} JOut;

static void jo_put(JOut *o, const unsigned char *bytes, size_t n) {
    if (!o->buf || o->full) return;
    if (o->len + n + 1 > o->cap) { o->full = 1; return; }
    memcpy(o->buf + o->len, bytes, n);
    o->len += n;
}

static void jo_put_cp(JOut *o, uint32_t cp) {
    unsigned char b[4];
    size_t n;
    if (cp < 0x80) { b[0] = (unsigned char)cp; n = 1; }
    else if (cp < 0x800) { b[0] = (unsigned char)(0xC0 | (cp >> 6)); b[1] = (unsigned char)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        b[0] = (unsigned char)(0xE0 | (cp >> 12)); b[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (unsigned char)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        b[0] = (unsigned char)(0xF0 | (cp >> 18)); b[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F)); b[3] = (unsigned char)(0x80 | (cp & 0x3F)); n = 4;
    }
    jo_put(o, b, n);
}

static int j_hex4(JCur *c, uint32_t *out) {
    if (c->end - c->p < 4) return -1;
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
        char h = c->p[i];
        v <<= 4;
        if (h >= '0' && h <= '9') v |= (uint32_t)(h - '0');
        else if (h >= 'a' && h <= 'f') v |= (uint32_t)(h - 'a' + 10);
        else if (h >= 'A' && h <= 'F') v |= (uint32_t)(h - 'A' + 10);
        else return -1;
    }
    c->p += 4;
    *out = v;
    return 0;
}

/* Parses a JSON string at the cursor. buf may be NULL (value skipped). Output is
 * NUL-terminated and silently truncated at a code-point boundary. */
static int j_string(JCur *c, char *buf, size_t cap) {
    JOut o = { buf, cap, 0, 0 };
    if (j_expect(c, '"') != 0) return -1;
    while (c->p < c->end) {
        unsigned char ch = (unsigned char)*c->p;
        if (ch == '"') {
            c->p++;
            if (buf && cap) buf[o.len] = '\0';
            return 0;
        }
        if (ch < 0x20) return -1;
        if (ch == '\\') {
            c->p++;
            if (c->p >= c->end) return -1;
            char e = *c->p++;
            unsigned char lit;
            switch (e) {
                case '"': lit = '"'; break;
                case '\\': lit = '\\'; break;
                case '/': lit = '/'; break;
                case 'b': lit = '\b'; break;
                case 'f': lit = '\f'; break;
                case 'n': lit = '\n'; break;
                case 'r': lit = '\r'; break;
                case 't': lit = '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (j_hex4(c, &cp) != 0) return -1;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        uint32_t lo;
                        if (c->end - c->p >= 6 && c->p[0] == '\\' && c->p[1] == 'u') {
                            c->p += 2;
                            if (j_hex4(c, &lo) != 0) return -1;
                            if (lo >= 0xDC00 && lo <= 0xDFFF) cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            else { jo_put_cp(&o, 0xFFFD); cp = lo; }
                        } else {
                            cp = 0xFFFD;
                        }
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        cp = 0xFFFD;
                    }
                    if (cp == 0) cp = 0xFFFD; /* never embed NUL */
                    jo_put_cp(&o, cp);
                    continue;
                }
                default: return -1;
            }
            jo_put(&o, &lit, 1);
            continue;
        }
        /* raw UTF-8: copy a well-formed sequence atomically, replace malformed bytes by U+FFFD */
        size_t n = 0;
        if (ch < 0x80) n = 1;
        else if (ch >= 0xC2 && ch <= 0xDF) n = 2;
        else if (ch >= 0xE0 && ch <= 0xEF) n = 3;
        else if (ch >= 0xF0 && ch <= 0xF4) n = 4;
        int ok = n > 0 && (size_t)(c->end - c->p) >= n;
        for (size_t i = 1; ok && i < n; ++i)
            if (((unsigned char)c->p[i] & 0xC0) != 0x80) ok = 0;
        if (ok) {
            jo_put(&o, (const unsigned char *)c->p, n);
            c->p += n;
        } else {
            jo_put_cp(&o, 0xFFFD);
            c->p += 1;
        }
    }
    return -1; /* unterminated */
}

/* Locale-independent JSON number parser. */
static int j_number(JCur *c, double *out) {
    j_ws(c);
    const char *p = c->p;
    int neg = 0;
    if (p < c->end && *p == '-') { neg = 1; p++; }
    if (p >= c->end || *p < '0' || *p > '9') return -1;
    double v = 0.0;
    if (*p == '0') p++;
    else while (p < c->end && *p >= '0' && *p <= '9') { v = v * 10.0 + (*p - '0'); p++; }
    if (p < c->end && *p == '.') {
        p++;
        if (p >= c->end || *p < '0' || *p > '9') return -1;
        double scale = 0.1;
        while (p < c->end && *p >= '0' && *p <= '9') { v += (*p - '0') * scale; scale *= 0.1; p++; }
    }
    if (p < c->end && (*p == 'e' || *p == 'E')) {
        p++;
        int eneg = 0, ex = 0;
        if (p < c->end && (*p == '+' || *p == '-')) { eneg = (*p == '-'); p++; }
        if (p >= c->end || *p < '0' || *p > '9') return -1;
        while (p < c->end && *p >= '0' && *p <= '9') { if (ex < 1000) ex = ex * 10 + (*p - '0'); p++; }
        double m = 1.0;
        for (int i = 0; i < ex && i < 400; ++i) m *= 10.0;
        v = eneg ? v / m : v * m;
    }
    c->p = p;
    *out = neg ? -v : v;
    return 0;
}

static int j_skip_value(JCur *c);

static int j_skip_container(JCur *c, char open, char close) {
    if (++c->depth > SR_JSON_MAX_DEPTH) return -1;
    if (j_expect(c, open) != 0) return -1;
    if (j_peek(c) == (unsigned char)close) { c->p++; c->depth--; return 0; }
    for (;;) {
        if (open == '{') {
            if (j_string(c, NULL, 0) != 0) return -1;
            if (j_expect(c, ':') != 0) return -1;
        }
        if (j_skip_value(c) != 0) return -1;
        int n = j_peek(c);
        if (n == ',') { c->p++; continue; }
        if (n == (unsigned char)close) { c->p++; c->depth--; return 0; }
        return -1;
    }
}

static int j_skip_value(JCur *c) {
    int ch = j_peek(c);
    double d;
    switch (ch) {
        case '{': return j_skip_container(c, '{', '}');
        case '[': return j_skip_container(c, '[', ']');
        case '"': return j_string(c, NULL, 0);
        case 't': return j_literal(c, "true");
        case 'f': return j_literal(c, "false");
        case 'n': return j_literal(c, "null");
        default:  return j_number(c, &d);
    }
}

/* Reads a boolean; returns 1 if a bool was present (value in *b), 0 if another type was
 * skipped, -1 on syntax error. */
static int j_bool(JCur *c, int *b) {
    int ch = j_peek(c);
    if (ch == 't') { if (j_literal(c, "true") != 0) return -1; *b = 1; return 1; }
    if (ch == 'f') { if (j_literal(c, "false") != 0) return -1; *b = 0; return 1; }
    return j_skip_value(c) == 0 ? 0 : -1;
}

/* Reads a number; 1 if number present, 0 if other type skipped, -1 syntax error. */
static int j_num_field(JCur *c, double *d) {
    int ch = j_peek(c);
    if (ch == '-' || (ch >= '0' && ch <= '9')) return j_number(c, d) == 0 ? 1 : -1;
    return j_skip_value(c) == 0 ? 0 : -1;
}

/* Reads a string; 1 if string present, 0 if other type skipped, -1 syntax error. */
static int j_str_field(JCur *c, char *buf, size_t cap) {
    if (j_peek(c) == '"') return j_string(c, buf, cap) == 0 ? 1 : -1;
    return j_skip_value(c) == 0 ? 0 : -1;
}

/* ------------------------------------------------------------------ devices.json */

/* UID validation / normalisation: [0-9A-Fa-f-] only, >= 24 hex digits (shm name). */
static int normalise_id(char *id) {
    size_t hex = 0;
    for (char *p = id; *p; ++p) {
        char ch = *p;
        if (ch >= 'a' && ch <= 'f') { *p = (char)(ch - 'a' + 'A'); hex++; }
        else if ((ch >= 'A' && ch <= 'F') || (ch >= '0' && ch <= '9')) hex++;
        else if (ch != '-') return -1;
    }
    return hex >= 24 ? 0 : -1;
}

/* Parses one device object. Returns 0 (valid -> *d filled), 1 (skipped: invalid entry),
 * -1 (syntax error). */
static int parse_device(JCur *c, SRDevDesc *d) {
    memset(d, 0, sizeof *d);
    int haveId = 0, bad = 0, haveName = 0;
    double channels = SR_DEFAULT_CHANNELS, rate = SR_DEFAULT_RATE;
    d->passThru = 0;

    if (j_peek(c) != '{') return j_skip_value(c) == 0 ? 1 : -1;
    if (++c->depth > SR_JSON_MAX_DEPTH) return -1;
    c->p++;
    if (j_peek(c) == '}') { c->p++; c->depth--; return 1; }
    for (;;) {
        char key[32];
        if (j_string(c, key, sizeof key) != 0) return -1;
        if (j_expect(c, ':') != 0) return -1;
        int r;
        if (strcmp(key, "id") == 0) {
            char tmp[SR_DEVDESC_ID_MAX + 8];
            r = j_str_field(c, tmp, sizeof tmp);
            if (r < 0) return -1;
            if (r == 1 && strlen(tmp) < SR_DEVDESC_ID_MAX) { memcpy(d->id, tmp, strlen(tmp) + 1); haveId = 1; }
            else bad = 1;
        } else if (strcmp(key, "name") == 0) {
            r = j_str_field(c, d->name, sizeof d->name);
            if (r < 0) return -1;
            haveName = (r == 1 && d->name[0] != '\0');
        } else if (strcmp(key, "channels") == 0) {
            r = j_num_field(c, &channels);
            if (r < 0) return -1;
            if (r == 0) bad = 1;
        } else if (strcmp(key, "sampleRate") == 0) {
            double v = 0;
            r = j_num_field(c, &v);
            if (r < 0) return -1;
            if (r == 1) rate = v;
        } else if (strcmp(key, "passThru") == 0) {
            int b = 0;
            r = j_bool(c, &b);
            if (r < 0) return -1;
            if (r == 1) d->passThru = b;
        } else {
            if (j_skip_value(c) != 0) return -1;
        }
        int n = j_peek(c);
        if (n == ',') { c->p++; continue; }
        if (n == '}') { c->p++; c->depth--; break; }
        return -1;
    }

    if (!haveId || bad || normalise_id(d->id) != 0) return 1;
    if (!(channels >= 1 && channels <= SR_MAX_CHANNELS)) return 1; /* also rejects NaN */
    if (channels != (double)(uint32_t)channels) return 1;
    d->channels = (uint32_t)channels;
    d->sampleRate = sr_rate_supported(rate) ? rate : SR_DEFAULT_RATE;
    if (!haveName) memcpy(d->name, SR_DEFAULT_NAME, sizeof SR_DEFAULT_NAME);
    return 0;
}

int sr_devices_json_parse(const char *json, size_t len,
                          SRDevDesc *out, uint32_t maxOut, uint32_t *outCount) {
    JCur c = { json, json + len, 0 };
    uint32_t count = 0;
    *outCount = 0;

    /* optional UTF-8 BOM */
    if (len >= 3 && (unsigned char)json[0] == 0xEF && (unsigned char)json[1] == 0xBB && (unsigned char)json[2] == 0xBF) c.p += 3;

    if (j_expect(&c, '{') != 0) return -1;
    c.depth = 1;
    if (j_peek(&c) == '}') { c.p++; goto done; }
    for (;;) {
        char key[32];
        if (j_string(&c, key, sizeof key) != 0) return -1;
        if (j_expect(&c, ':') != 0) return -1;
        if (strcmp(key, "devices") == 0 && j_peek(&c) == '[') {
            c.p++;
            c.depth++;
            if (j_peek(&c) == ']') { c.p++; c.depth--; }
            else for (;;) {
                SRDevDesc d;
                int r = parse_device(&c, &d);
                if (r < 0) return -1;
                if (r == 0 && count < maxOut) {
                    int dup = 0;
                    for (uint32_t i = 0; i < count; ++i)
                        if (strcmp(out[i].id, d.id) == 0) { dup = 1; break; }
                    if (!dup) out[count++] = d;
                }
                int n = j_peek(&c);
                if (n == ',') { c.p++; continue; }
                if (n == ']') { c.p++; c.depth--; break; }
                return -1;
            }
        } else {
            if (j_skip_value(&c) != 0) return -1;
        }
        int n = j_peek(&c);
        if (n == ',') { c.p++; continue; }
        if (n == '}') { c.p++; break; }
        return -1;
    }
done:
    if (j_peek(&c) != -1) return -1; /* trailing garbage */
    *outCount = count;
    return 0;
}

/* ------------------------------------------------------------------ diff */

uint32_t sr_devlist_diff(const SRDevDesc *oldList, uint32_t nOld,
                         const SRDevDesc *newList, uint32_t nNew,
                         SRDiffOp *ops, uint32_t maxOps) {
    uint32_t n = 0;
#define EMIT(k, o, nw, ch) do { if (n < maxOps) { ops[n].kind = (k); ops[n].oldIndex = (o); ops[n].newIndex = (nw); ops[n].changes = (ch); n++; } } while (0)

    /* pass 1: removals */
    for (uint32_t i = 0; i < nOld; ++i) {
        int found = 0;
        for (uint32_t j = 0; j < nNew; ++j)
            if (strcmp(oldList[i].id, newList[j].id) == 0) { found = 1; break; }
        if (!found) EMIT(SR_DIFF_REMOVE, (int32_t)i, -1, 0u);
    }
    /* pass 2/3: recreate and update, in old order */
    for (int pass = 0; pass < 2; ++pass) {
        for (uint32_t i = 0; i < nOld; ++i) {
            for (uint32_t j = 0; j < nNew; ++j) {
                if (strcmp(oldList[i].id, newList[j].id) != 0) continue;
                uint32_t ch = 0;
                if (strcmp(oldList[i].name, newList[j].name) != 0) ch |= SR_CHG_NAME;
                if (oldList[i].channels != newList[j].channels) ch |= SR_CHG_CHANNELS;
                if (oldList[i].sampleRate != newList[j].sampleRate) ch |= SR_CHG_RATE;
                if ((oldList[i].passThru != 0) != (newList[j].passThru != 0)) ch |= SR_CHG_PASSTHRU;
                if (pass == 0 && (ch & SR_CHG_PASSTHRU)) EMIT(SR_DIFF_RECREATE, (int32_t)i, (int32_t)j, ch);
                if (pass == 1 && ch && !(ch & SR_CHG_PASSTHRU)) EMIT(SR_DIFF_UPDATE, (int32_t)i, (int32_t)j, ch);
                break;
            }
        }
    }
    /* pass 4: additions, in new order */
    for (uint32_t j = 0; j < nNew; ++j) {
        int found = 0;
        for (uint32_t i = 0; i < nOld; ++i)
            if (strcmp(oldList[i].id, newList[j].id) == 0) { found = 1; break; }
        if (!found) EMIT(SR_DIFF_ADD, -1, (int32_t)j, 0u);
    }
#undef EMIT
    return n;
}
