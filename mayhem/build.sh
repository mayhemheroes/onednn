#!/usr/bin/env bash
#
# onednn/mayhem/build.sh — build the oneDNN graph JSON-deserializer OSS-Fuzz harness (fuzz_json)
# as a sanitized libFuzzer target, plus a standalone reproducer.
#
# fuzz_json exercises dnnl::impl::graph::utils::json::json_reader_t / read_helper_t
# (src/graph/utils/json.hpp) — oneDNN graph's JSON deserialization utility (also used internally
# by src/graph/utils/pm/pass_manager.cpp to load a pass_config.json). That class is HEADER-ONLY
# (fully inline in json.hpp): it needs no compiled oneDNN library (libdnnl) to build or run.
# Upstream's OSS-Fuzz build.sh builds the WHOLE static libdnnl.a with cmake (DNNL_BUILD_TESTS=OFF
# DNNL_BUILD_EXAMPLES=OFF) and links it into the harness, but nothing in libdnnl.a is actually
# referenced by fuzz_json.cpp (confirmed: the harness links and runs identically with -Isrc and
# no library at all). So we scope the build to exactly what the harness needs — the header —
# skipping cmake/the graph library build entirely. This keeps the build tiny, fast, and trivially
# air-gapped: no third-party fetch, no OpenMP/BLAS deps, no network access of any kind.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
JSON_INC="-I$SRC/src/graph/utils"
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# Standalone driver (plain C, no libFuzzer runtime; provided by the base image). Compile it as a
# C object once — clang++ would otherwise mangle its LLVMFuzzerTestOneInput reference.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# EXPERIMENT (LSan-necessity test): NO asan_options / detect_leaks=0 here — testing whether Mayhem's
# libFuzzer-mode analysis handles ASan/ptrace itself (so the LSan fix is unnecessary).

# ── libFuzzer target -> /mayhem/fuzz_json ───────────────────────────────────────────────────────
$CXX -std=c++14 $SANITIZER_FLAGS $DEBUG_FLAGS $JSON_INC \
    "$HARNESS_DIR/fuzz_json.cpp" $LIB_FUZZING_ENGINE \
    -o /mayhem/fuzz_json

# ── standalone reproducer (no libFuzzer runtime) -> /mayhem/fuzz_json-standalone ────────────────
$CXX -std=c++14 $SANITIZER_FLAGS $DEBUG_FLAGS $JSON_INC \
    "$HARNESS_DIR/fuzz_json.cpp" "$BUILD/standalone_main.o" \
    -o /mayhem/fuzz_json-standalone

# FIX (real 0-edge cause): place the dictionary the Mayhemfile references (build.sh never did) so
# libFuzzer doesn't exit 1 on a missing -dict path.
cp "$SRC/mayhem/fuzz_json.dict" /mayhem/fuzz_json.dict

echo "build.sh complete:"
ls -la /mayhem/fuzz_json /mayhem/fuzz_json-standalone
