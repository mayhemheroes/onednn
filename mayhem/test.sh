#!/usr/bin/env bash
#
# onednn/mayhem/test.sh — behavioral KAT oracle for the fuzz_json harness.
#
# fuzz_json.cpp declares three fields on its read_helper_t: a string ("op_kind"), an integer
# ("version"), and an array of integers ("dims") — the same field KINDS oneDNN's own graph-JSON
# loader declares in src/graph/utils/pm/pass_manager.cpp ("pass_name"/"priority"/"passes"). When
# MAYHEM_KAT_PRINT is set the harness prints a value it COMPUTED from what it actually parsed
# (dims_product = product of the "dims" array) — not an echo of the input. We feed the standalone
# reproducer (/mayhem/fuzz_json-standalone, linked against StandaloneFuzzTargetMain) two FIXED,
# valid graph-JSON objects and assert the EXACT derived line for each. A no-op/exit(0) neuter (the
# whole process gets _exit(0)'d in a constructor before main under verify-repo's sabotage check)
# or a broken parser cannot produce this output.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC="${SRC:-/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

echo "=== onednn fuzz_json behavioral KAT oracle ==="
PASSED=0; FAILED=0

STANDALONE="/mayhem/fuzz_json-standalone"
if [ ! -x "$STANDALONE" ]; then
  echo "  FAIL $STANDALONE missing — build failed?"
  emit_ctrf "onednn-json-kat" 0 1 0
  exit 1
fi
echo "  PASS $STANDALONE exists"
PASSED=$((PASSED+1))

# ── KAT 1 ─────────────────────────────────────────────────────────────────────────────────────
KAT1=/tmp/onednn_kat1.json
cat > "$KAT1" <<'JSON'
{"op_kind": "MatMul", "version": 5, "dims": [2, 3, 4]}
JSON
EXPECTED1="KAT op_kind=MatMul version=5 dims_product=24"

echo "  Running fuzz_json-standalone on a fixed, valid graph-JSON object..."
OUT1="$(MAYHEM_KAT_PRINT=1 timeout 10 "$STANDALONE" "$KAT1" 2>/tmp/onednn_kat_stderr.log)"
rc1=$?
if [ "$rc1" -ne 0 ]; then
  echo "  FAIL standalone exited $rc1 on KAT1 (expected 0 on valid input)"
  FAILED=$((FAILED+1))
elif echo "$OUT1" | grep -qF "$EXPECTED1"; then
  echo "  PASS computed KAT line matched: $EXPECTED1"
  PASSED=$((PASSED+1))
else
  echo "  FAIL expected KAT line not found."
  echo "       expected: $EXPECTED1"
  echo "       got:      $OUT1"
  FAILED=$((FAILED+1))
fi

# ── KAT 2 (different field order + values — guards against a hardcoded single-string oracle) ───
KAT2=/tmp/onednn_kat2.json
cat > "$KAT2" <<'JSON'
{"version": 100, "dims": [5, 5], "op_kind": "Convolution"}
JSON
EXPECTED2="KAT op_kind=Convolution version=100 dims_product=25"

OUT2="$(MAYHEM_KAT_PRINT=1 timeout 10 "$STANDALONE" "$KAT2" 2>>/tmp/onednn_kat_stderr.log)"
rc2=$?
if [ "$rc2" -ne 0 ]; then
  echo "  FAIL standalone exited $rc2 on KAT2 (expected 0 on valid input)"
  FAILED=$((FAILED+1))
elif echo "$OUT2" | grep -qF "$EXPECTED2"; then
  echo "  PASS second computed KAT line matched: $EXPECTED2"
  PASSED=$((PASSED+1))
else
  echo "  FAIL expected second KAT line not found."
  echo "       expected: $EXPECTED2"
  echo "       got:      $OUT2"
  FAILED=$((FAILED+1))
fi

# ── KAT 3: malformed input must NOT crash (upstream's own contract). Fixed (not random) bytes
# so this stays deterministic run to run. ───────────────────────────────────────────────────────
KAT3=/tmp/onednn_kat3.bin
printf '{"op_kind": "X, "version": [[[}}}\\uZZZZ\x01\x02\xff\xfe not json at all' > "$KAT3"
timeout 10 "$STANDALONE" "$KAT3" >/tmp/onednn_kat3_stdout.log 2>>/tmp/onednn_kat_stderr.log
rc3=$?
if [ "$rc3" -eq 0 ]; then
  echo "  PASS garbage input handled without crashing (rc=0)"
  PASSED=$((PASSED+1))
else
  echo "  FAIL garbage input crashed the parser (rc=$rc3)"
  FAILED=$((FAILED+1))
fi

echo ""
echo "=== Oracle summary: $PASSED passed, $FAILED failed ==="
emit_ctrf "onednn-json-kat" "$PASSED" "$FAILED" 0
