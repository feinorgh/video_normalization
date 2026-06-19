#!/usr/bin/env bash
set -euo pipefail

SCRIPT="./video_normalize.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { printf "PASS: %s\n" "$1"; }
fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

# 1) Help should work
if "$SCRIPT" --help >/dev/null 2>&1; then
  pass "--help exits successfully"
else
  fail "--help should succeed"
fi

# 2) Unknown option should fail
if "$SCRIPT" --definitely-not-a-real-flag >/dev/null 2>&1; then
  fail "unknown option should fail"
else
  pass "unknown option fails as expected"
fi

# 3) Invalid numeric should fail fast before heavy processing
if "$SCRIPT" --vmaf-threshold nope >/dev/null 2>&1; then
  fail "invalid --vmaf-threshold should fail"
else
  pass "invalid --vmaf-threshold rejected"
fi

# 4) min-crf > start-crf should fail
if "$SCRIPT" --start-crf 20 --min-crf 22 >/dev/null 2>&1; then
  fail "min-crf > start-crf should fail"
else
  pass "min-crf/start-crf validation works"
fi

# 5) report file should be initialized even on empty source dir
mkdir -p "$TMP_DIR/empty"
REPORT="$TMP_DIR/report.csv"
"$SCRIPT" --dry-run --report "$REPORT" "$TMP_DIR/empty" >/dev/null 2>&1 || fail "dry-run on empty dir should succeed"

if [[ -f "$REPORT" ]] && grep -q '^source_file,codec,duration,action,status,crf,preset,vmaf,ssim,sample_ratio,final_ratio,message$' "$REPORT"; then
  pass "report header written"
else
  fail "report header missing"
fi

printf "\nAll smoke checks passed.\n"
