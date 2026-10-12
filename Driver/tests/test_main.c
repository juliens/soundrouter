// Unit tests for the pure parts of the SoundRouter driver (no coreaudiod needed):
// devices.json parser, device-list diff, ring index math. `make test` in Driver/.

#include "sr_devices.h"
#include "sr_ring.h"
#include "sr_shm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int gFails, gChecks;
#define CHECK(cond) do { gChecks++; if (!(cond)) { gFails++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static int parse(const char *js, SRDevDesc *out, uint32_t *n) {
    return sr_devices_json_parse(js, strlen(js), out, SR_MAX_DEVICES, n);
}

#define U1 "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"
#define U2 "2B4E28BA-2FA1-11D2-883F-0016D3CCA427"
#define U3 "3B4E28BA-2FA1-11D2-883F-0016D3CCA427"

static void test_json(void) {
    SRDevDesc d[SR_MAX_DEVICES];
    uint32_t n = 99;

    const char *spec =
        "{ \"schemaVersion\": 1, \"devices\": [ { \"id\": \"" U1 "\", \"name\": \"Mix 1\", \"channels\": 2,"
        " \"sampleRate\": 48000, \"passThru\": true } ] }";
    CHECK(parse(spec, d, &n) == 0);
    CHECK(n == 1);
    CHECK(strcmp(d[0].id, U1) == 0);
    CHECK(strcmp(d[0].name, "Mix 1") == 0);
    CHECK(d[0].channels == 2 && d[0].sampleRate == 48000.0 && d[0].passThru == 1);

    /* lowercase id normalised; defaults; unknown nested keys skipped; key order free */
    const char *js2 =
        "\xEF\xBB\xBF{\"extra\":{\"a\":[1,2,{\"b\":null}],\"c\":\"x\\\"y\"},\"devices\":["
        "{\"passThru\":false,\"id\":\"1b4e28ba-2fa1-11d2-883f-0016d3cca427\",\"future\":[true]},"
        "{\"id\":\"" U2 "\",\"channels\":64,\"sampleRate\":44100.0,\"name\":\"\"},"
        "{\"id\":\"" U3 "\",\"channels\":8,\"sampleRate\":22050}"
        "],\"schemaVersion\":2}";
    CHECK(parse(js2, d, &n) == 0);
    CHECK(n == 3);
    CHECK(strcmp(d[0].id, U1) == 0 && d[0].channels == 2 && d[0].sampleRate == 48000.0 && d[0].passThru == 0);
    CHECK(strcmp(d[0].name, SR_DEFAULT_NAME) == 0);
    CHECK(d[1].channels == 64 && d[1].sampleRate == 44100.0 && strcmp(d[1].name, SR_DEFAULT_NAME) == 0);
    CHECK(d[2].channels == 8 && d[2].sampleRate == 48000.0); /* unsupported rate -> default */

    /* invalid entries skipped, duplicates keep the first */
    const char *js3 =
        "{\"devices\":["
        "{\"id\":\"" U1 "\",\"channels\":0},"
        "{\"id\":\"" U1 "\",\"channels\":65},"
        "{\"id\":\"" U1 "\",\"channels\":2.5},"
        "{\"id\":\"" U1 "\",\"channels\":\"2\"},"
        "{\"name\":\"no id\"},"
        "{\"id\":\"1234-5678\"},"                       /* too few hex digits */
        "{\"id\":\"" U1 "/../x\"},"                     /* illegal characters */
        "{\"id\":42},"
        "7, null, \"str\", [],"
        "{\"id\":\"" U2 "\",\"channels\":1,\"name\":\"first\"},"
        "{\"id\":\"" U2 "\",\"channels\":4,\"name\":\"dup\"},"
        "{\"id\":\"" U3 "\",\"channels\":1e1}"
        "]}";
    CHECK(parse(js3, d, &n) == 0);
    CHECK(n == 2);
    CHECK(strcmp(d[0].id, U2) == 0 && strcmp(d[0].name, "first") == 0 && d[0].channels == 1);
    CHECK(strcmp(d[1].id, U3) == 0 && d[1].channels == 10);

    /* escapes + UTF-8 */
    const char *js4 = "{\"devices\":[{\"id\":\"" U1 "\",\"name\":\"Caf\\u00e9 \\ud83c\\udfb5 \\\"q\\\" \\/ \xC3\xA9\"}]}";
    CHECK(parse(js4, d, &n) == 0 && n == 1);
    CHECK(strcmp(d[0].name, "Caf\xC3\xA9 \xF0\x9F\x8E\xB5 \"q\" / \xC3\xA9") == 0);

    /* malformed UTF-8 is replaced, lone surrogate -> U+FFFD */
    const char *js5 = "{\"devices\":[{\"id\":\"" U1 "\",\"name\":\"a\xFF" "b\\udc00\"}]}";
    CHECK(parse(js5, d, &n) == 0 && n == 1);
    CHECK(strcmp(d[0].name, "a\xEF\xBF\xBD" "b\xEF\xBF\xBD") == 0);

    /* name truncation never cuts a code point: 126 'a' + "é" (2 bytes) does not fit in 127 */
    {
        char js[600], name[200];
        memset(name, 'a', 126); name[126] = '\0';
        snprintf(js, sizeof js, "{\"devices\":[{\"id\":\"" U1 "\",\"name\":\"%s\xC3\xA9zz\"}]}", name);
        CHECK(parse(js, d, &n) == 0 && n == 1);
        CHECK(strlen(d[0].name) == 126);
    }

    /* no devices key / empty */
    CHECK(parse("{}", d, &n) == 0 && n == 0);
    CHECK(parse("{\"schemaVersion\":1}", d, &n) == 0 && n == 0);
    CHECK(parse("{\"devices\":[]}", d, &n) == 0 && n == 0);
    CHECK(parse("  {\"devices\" : [ ] }  \n", d, &n) == 0 && n == 0);

    /* syntax errors -> -1 (caller keeps its list) */
    const char *bad[] = {
        "", "   ", "[]", "null", "{", "{\"devices\":[}", "{\"devices\":[{\"id\":\"x\",}]}",
        "{\"devices\":[],}", "{\"devices\":[]} x", "{\"a\":tru}", "{\"a\":\"unterminated}",
        "{\"a\":\"ctl\x01\"}", "{\"a\":01x}", "{\"a\":-}", "{\"a\":1.}", "{\"a\":\"\\q\"}",
        "{\"a\":\"\\u12G4\"}", "{'a':1}",
        "{\"devices\":[{\"id\":\"" U1 "\",\"channels\":2}" /* truncated file */
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; ++i) {
        n = 77;
        int r = parse(bad[i], d, &n);
        if (r != -1) fprintf(stderr, "  bad[%zu] accepted: %s\n", i, bad[i]);
        CHECK(r == -1);
        CHECK(n == 0);
    }

    /* nesting limit */
    {
        char js[400];
        size_t p = 0;
        p += (size_t)snprintf(js + p, sizeof js - p, "{\"x\":");
        for (int i = 0; i < 100; ++i) js[p++] = '[';
        for (int i = 0; i < 100; ++i) js[p++] = ']';
        js[p++] = '}'; js[p] = '\0';
        CHECK(parse(js, d, &n) == -1);
    }

    /* maxOut respected */
    {
        uint32_t m = 0;
        CHECK(sr_devices_json_parse(js2, strlen(js2), d, 1, &m) == 0 && m == 1);
    }

    /* not NUL-terminated input: parse only len bytes */
    {
        const char *js = "{\"devices\":[]}GARBAGE";
        CHECK(sr_devices_json_parse(js, 14, d, SR_MAX_DEVICES, &n) == 0 && n == 0);
    }

    CHECK(sr_rate_supported(44100) && sr_rate_supported(192000) && !sr_rate_supported(22050) && !sr_rate_supported(48000.5));
}

static SRDevDesc mk(const char *id, const char *name, uint32_t ch, double rate, int pt) {
    SRDevDesc d;
    memset(&d, 0, sizeof d);
    strcpy(d.id, id); strcpy(d.name, name);
    d.channels = ch; d.sampleRate = rate; d.passThru = pt;
    return d;
}

static void test_diff(void) {
    SRDiffOp ops[16];
    SRDevDesc a[3] = { mk(U1, "A", 2, 48000, 1), mk(U2, "B", 2, 48000, 0), mk(U3, "C", 2, 48000, 1) };

    /* identical -> no op */
    CHECK(sr_devlist_diff(a, 3, a, 3, ops, 16) == 0);
    /* empty -> all adds, in order */
    uint32_t n = sr_devlist_diff(NULL, 0, a, 3, ops, 16);
    CHECK(n == 3 && ops[0].kind == SR_DIFF_ADD && ops[0].newIndex == 0 && ops[2].newIndex == 2 && ops[1].oldIndex == -1);
    /* all removed */
    n = sr_devlist_diff(a, 3, NULL, 0, ops, 16);
    CHECK(n == 3 && ops[0].kind == SR_DIFF_REMOVE && ops[1].oldIndex == 1);

    /* mixed: U1 renamed + rate, U2 removed, U3 passThru off (recreate), new U4 */
    SRDevDesc b[3] = { mk("4B4E28BA-2FA1-11D2-883F-0016D3CCA427", "D", 4, 96000, 1),
                       mk(U3, "C", 2, 48000, 0), mk(U1, "A2", 2, 96000, 1) };
    n = sr_devlist_diff(a, 3, b, 3, ops, 16);
    CHECK(n == 4);
    CHECK(ops[0].kind == SR_DIFF_REMOVE && ops[0].oldIndex == 1);
    CHECK(ops[1].kind == SR_DIFF_RECREATE && ops[1].oldIndex == 2 && ops[1].newIndex == 1 && (ops[1].changes & SR_CHG_PASSTHRU));
    CHECK(ops[2].kind == SR_DIFF_UPDATE && ops[2].oldIndex == 0 && ops[2].newIndex == 2
          && ops[2].changes == (SR_CHG_NAME | SR_CHG_RATE));
    CHECK(ops[3].kind == SR_DIFF_ADD && ops[3].newIndex == 0);

    /* channels only */
    SRDevDesc c[1] = { mk(U1, "A", 8, 48000, 1) };
    n = sr_devlist_diff(a, 1, c, 1, ops, 16);
    CHECK(n == 1 && ops[0].kind == SR_DIFF_UPDATE && ops[0].changes == SR_CHG_CHANNELS);

    /* maxOps bound */
    CHECK(sr_devlist_diff(NULL, 0, a, 3, ops, 2) == 2);
}

#define RING SR_RING_FRAMES

static void test_ring(void) {
    uint32_t f, c;
    sr_ring_valid_range(1000, 900, 50, &f, &c);      CHECK(f == 0 && c == 50);
    sr_ring_valid_range(1000, 980, 50, &f, &c);      CHECK(f == 0 && c == 20);   /* tail not yet written */
    sr_ring_valid_range(1000, 1000, 50, &f, &c);     CHECK(c == 0);
    sr_ring_valid_range(1000, 2000, 50, &f, &c);     CHECK(c == 0);
    sr_ring_valid_range(RING + 100, 90, 20, &f, &c); CHECK(f == 10 && c == 10); /* head too old */
    sr_ring_valid_range(RING + 100, 0, 50, &f, &c);  CHECK(c == 0);
    sr_ring_valid_range(0, -10, 5, &f, &c);          CHECK(f == 0 && c == 5);   /* contract: [w-RING, w) */
    sr_ring_valid_range(0, 0, 5, &f, &c);            CHECK(c == 0);             /* nothing written yet */
    sr_ring_valid_range(5, -10, 20, &f, &c);         CHECK(f == 0 && c == 15);  /* negative sample times */

    const uint32_t CH = 3;
    float *planes = calloc((size_t)CH * RING, sizeof(float));
    const uint32_t N = 512;
    float in[512 * 3], out[512 * 4];
    int64_t start = (int64_t)RING * 7 - 200;  /* crosses the wrap */
    for (uint32_t k = 0; k < N; ++k)
        for (uint32_t ch = 0; ch < CH; ++ch) in[k * CH + ch] = (float)(start + k) + 0.25f * (float)ch;

    /* interleaved write -> read roundtrip, bit exact */
    sr_ring_write(planes, CH, start, N, in, CH, 1);
    CHECK(planes[(uint64_t)start & SR_RING_MASK] == (float)start);
    CHECK(planes[1 * RING + 0] == (float)(start + 200) + 0.25f); /* frame at index 0 after wrap */
    memset(out, 0x7f, sizeof out);
    uint32_t v = sr_ring_read(planes, CH, start + N, start, N, out, CH, 1);
    CHECK(v == N);
    CHECK(memcmp(out, in, (size_t)N * CH * sizeof(float)) == 0);

    /* partially written: tail zero */
    memset(out, 0x7f, sizeof out);
    v = sr_ring_read(planes, CH, start + 100, start, N, out, CH, 1);
    CHECK(v == 100);
    CHECK(out[99 * CH + 2] == in[99 * CH + 2] && out[100 * CH] == 0.0f && out[(N - 1) * CH + 2] == 0.0f);

    /* too old: all zero */
    memset(out, 0x7f, sizeof out);
    v = sr_ring_read(planes, CH, start + N + RING, start, N, out, CH, 1);
    CHECK(v == 0 && out[0] == 0.0f && out[N * CH - 1] == 0.0f);

    /* more output channels than planes: extra channel zero */
    memset(out, 0x7f, sizeof out);
    v = sr_ring_read(planes, CH, start + N, start, N, out, CH + 1, 1);
    CHECK(v == N && out[0] == in[0] && out[3] == 0.0f && out[4 + 1] == in[CH + 1] && out[N * 4 - 1] == 0.0f);

    /* non-interleaved read */
    memset(out, 0x7f, sizeof out);
    v = sr_ring_read(planes, CH, start + N - 12, start, N, out, CH, 0);
    CHECK(v == N - 12);
    int okni = 1;
    for (uint32_t ch = 0; ch < CH; ++ch)
        for (uint32_t k = 0; k < N; ++k) {
            float want = k < N - 12 ? in[k * CH + ch] : 0.0f;
            if (out[ch * N + k] != want) okni = 0;
        }
    CHECK(okni);

    /* non-interleaved write roundtrip with wrap */
    float ni[512 * 3];
    for (uint32_t ch = 0; ch < CH; ++ch)
        for (uint32_t k = 0; k < N; ++k) ni[ch * N + k] = -(float)k - 1000.0f * (float)ch;
    int64_t s2 = -300; /* negative sample times wrap too */
    sr_ring_write(planes, CH, s2, N, ni, CH, 0);
    v = sr_ring_read(planes, CH, s2 + N, s2, N, out, CH, 0);
    CHECK(v == N && memcmp(out, ni, sizeof ni) == 0);

    /* write with fewer input channels zeroes the rest */
    sr_ring_write(planes, CH, 0, 4, in, 1, 1);
    CHECK(planes[0] == in[0] && planes[1] == in[1] && planes[RING + 0] == 0.0f && planes[2 * RING + 3] == 0.0f);

    /* n > ring: only last RING frames kept */
    {
        uint32_t big = RING + 10;
        float *bin = malloc(sizeof(float) * big);
        for (uint32_t k = 0; k < big; ++k) bin[k] = (float)k;
        sr_ring_write(planes, 1, 5, big, bin, 1, 1);
        CHECK(planes[(5 + 10) & SR_RING_MASK] == 10.0f);
        CHECK(planes[(5 + big - 1) & SR_RING_MASK] == (float)(big - 1));
        free(bin);
    }

    /* NULL planes -> silence */
    memset(out, 0x7f, sizeof out);
    CHECK(sr_ring_read(NULL, 0, 100, 0, 16, out, 2, 1) == 0 && out[0] == 0.0f && out[31] == 0.0f);

    free(planes);

    _Atomic int64_t w = 10;
    CHECK(sr_atomic_max_i64(&w, 5) == 10 && w == 10);
    CHECK(sr_atomic_max_i64(&w, 50) == 50 && w == 50);
}

static void test_shm_contract(void) {
    char name[SR_SHM_NAME_MAX + 1];
    sr_shm_name(U1, name);
    CHECK(strcmp(name, "/sr.1b4e28ba2fa111d2883f0016") == 0);
    CHECK(sr_shm_size(2) == 512 + 2u * 2u * RING * 4u);
}

int main(void) {
    test_json();
    test_diff();
    test_ring();
    test_shm_contract();
    printf("%d/%d checks passed\n", gChecks - gFails, gChecks);
    return gFails ? 1 : 0;
}
