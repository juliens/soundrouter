# Source this before running swift in the Claude sandbox: redirects caches to $TMPDIR.
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clang-mc"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
# usage: srbuild <scratch-name> [swift build args...]
srbuild() { local n="$1"; shift; swift build --scratch-path ".build/$n" --cache-path "${TMPDIR:-/tmp}/spmcache" --manifest-cache local --disable-sandbox "$@" 2>&1 | grep -v -e 'xcrun_db' -e DVTFilePathFSEvents; }
srtest()  { local n="$1"; shift; swift test  --scratch-path ".build/$n" --cache-path "${TMPDIR:-/tmp}/spmcache" --manifest-cache local --disable-sandbox "$@" 2>&1 | grep -v -e 'xcrun_db' -e DVTFilePathFSEvents; }
