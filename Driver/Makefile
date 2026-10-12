# SoundRouter HAL driver (AudioServerPlugIn) — universal build.
#   make          -> ../build/SoundRouter.driver (arm64 + x86_64, ad-hoc signed)
#   make test     -> unit tests of the pure parts (JSON, diff, ring math), host arch
#                    (always UBSan; `make test ASAN=1` adds AddressSanitizer)
#   make harness  -> in-process integration test of the full driver (fake host, real shm)
#   make clean
# SIGN_IDENTITY="Developer ID Application: ..." to sign with a real identity (hardened runtime).

# Apple clang is required (blocks, universal -arch); `cc` on PATH may be GCC.
ifeq ($(origin CC),default)
  CC := xcrun clang
endif
ROOT      := ..
BUILD     := $(ROOT)/build
OBJDIR    := $(BUILD)/driver-obj
BUNDLE    := $(BUILD)/SoundRouter.driver
EXE       := $(BUNDLE)/Contents/MacOS/SoundRouter
PLIST     := $(BUNDLE)/Contents/Info.plist
MINOS     := 14.2
ARCHS     := -arch arm64 -arch x86_64

CFLAGS_COMMON := -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -fblocks \
                 -mmacosx-version-min=$(MINOS) -I$(ROOT)/Sources/SRCore/include -Isrc
CFLAGS    := $(CFLAGS_COMMON) $(ARCHS) -fvisibility=hidden
LDFLAGS   := $(ARCHS) -bundle -mmacosx-version-min=$(MINOS) \
             -framework CoreAudio -framework CoreFoundation

SRCS      := src/sr_driver.c src/sr_devices.c src/sr_ring.c
OBJS      := $(patsubst src/%.c,$(OBJDIR)/%.o,$(SRCS))
HDRS      := src/sr_devices.h src/sr_ring.h $(ROOT)/Sources/SRCore/include/sr_shm.h

ifdef SIGN_IDENTITY
  CODESIGN := codesign --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)"
else
  CODESIGN := codesign --force --sign -
endif

.PHONY: all clean test harness FORCE
# Signing is cheap and idempotent: always (re)sign the bundle.
all: $(EXE) $(PLIST)
	$(CODESIGN) $(BUNDLE)

$(OBJDIR)/%.o: src/%.c $(HDRS) | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR):
	mkdir -p $@

$(EXE): $(OBJS)
	mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) $(OBJS) -o $@

$(PLIST): Info.plist
	mkdir -p $(dir $@)
	cp Info.plist $@
	plutil -lint $@ >/dev/null


# ------------------------------------------------------------------ tests
TEST_BIN := $(BUILD)/driver-tests/sr_driver_tests
TEST_CFLAGS := -O1 -g -fsanitize=undefined -fno-sanitize-recover=all
ifdef ASAN
  TEST_CFLAGS += -fsanitize=address
endif

test: $(TEST_BIN)
	$(TEST_BIN)

$(TEST_BIN): FORCE tests/test_main.c src/sr_devices.c src/sr_ring.c $(HDRS)
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) $(TEST_CFLAGS) tests/test_main.c src/sr_devices.c src/sr_ring.c -o $@

# In-process integration harness: the real driver code (built with -DSR_TESTING so the
# devices.json / J1 flag paths live in $$TMPDIR) driven through its COM interface with a
# fake host and a real shm segment. Takes ~15 s (reload / reap timers).
HARNESS_BIN := $(BUILD)/driver-tests/sr_driver_harness
harness: $(HARNESS_BIN)
	$(HARNESS_BIN)

$(HARNESS_BIN): FORCE tests/harness.c $(SRCS) $(HDRS)
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -O1 -g -fsanitize=undefined -DSR_TESTING tests/harness.c $(SRCS) \
	    -framework CoreAudio -framework CoreFoundation -o $@

FORCE:

clean:
	rm -rf $(BUNDLE) $(OBJDIR) $(BUILD)/driver-tests
