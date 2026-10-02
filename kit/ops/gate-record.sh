#!/usr/bin/env bash
# Record a local gate outcome against the commit it ran on. The CALLER cannot
# declare a verdict: it is derived from the RESULT line, because the exit code
# does not mean what it looks like.
#
# Contract for your gate (ops/local-ci.sh): print exactly one line
#     RESULT: <passed> passed, <failed> failed, <skipped> skipped
# A gate that exits 0 having run nothing prints "RESULT: 0 passed, 0 failed,
# 14 skipped" and reads as success. Recording that as a pass once published a
# green commit status certifying a no-op. Read the RESULT line, not the exit
# code. A skip is not a pass.
#
# Usage: gate-record.sh <sha> <filtered|all|none> [result-line] [fail-reason]
#   fail-reason: when non-empty the verdict is fail whatever the line says (the gate exited non-zero)
#   none -> the gate did not run (override, or absent on this branch)
#   all  -> only gate-attest.sh --run may write it (it ran the full gate itself)
# Verdict: failed>0 -> fail; passed==0 -> fail; no RESULT line -> fail; scope all with more skipped
# than passed -> fail (an environment was certified, not a tree); a fail-reason -> fail; else pass
set -uo pipefail
sha="${1:-}"; scope="${2:-}"; line="${3:-}"; reason="${4:-}"
[ -n "$sha" ] && [ -n "$scope" ] || { echo "usage: gate-record.sh <sha> <filtered|all|none> [result-line] [fail-reason]" >&2; exit 2; }
if [ "$scope" = all ] && [ "${KIT_GATE_RAN_ALL:-}" != "1" ]; then
  echo "gate-record: refusing a caller-asserted 'all'. Use: gate-attest.sh --run" >&2; exit 2
fi
case "$scope" in filtered|all|none) ;; *) echo "gate-record: scope must be filtered, all, or none" >&2; exit 2 ;; esac
dir="${KIT_GATE_STATE_DIR:-$HOME/.local/state/gate}"
mkdir -p "$dir" 2>/dev/null || true   # bookkeeping failing must never decide the verdict; the exit code at the end does

passed=""; failed=""; skipped=""
if [ -n "$line" ]; then
  passed="$(printf '%s' "$line" | sed -n 's/.*RESULT:[[:space:]]*\([0-9]\{1,\}\)[[:space:]]*passed.*/\1/p')"
  failed="$(printf '%s' "$line" | sed -n 's/.*passed,[[:space:]]*\([0-9]\{1,\}\)[[:space:]]*failed.*/\1/p')"
  skipped="$(printf '%s' "$line" | sed -n 's/.*failed,[[:space:]]*\([0-9]\{1,\}\)[[:space:]]*skipped.*/\1/p')"
fi
if [ "$scope" = none ]; then verdict=fail; why="gate did not run"
elif [ -z "$passed" ] || [ -z "$failed" ]; then verdict=fail; why="no parseable RESULT line"
elif [ "$failed" -gt 0 ] 2>/dev/null; then verdict=fail; why="$failed job(s) failed"
elif [ "$passed" -eq 0 ] 2>/dev/null; then verdict=fail; why="0 jobs ran (${skipped:-?} skipped): a no-op is not a pass"
elif [ "$scope" = all ] && [ "${skipped:-0}" -gt "$passed" ] 2>/dev/null; then
  verdict=fail; why="only $passed of $((passed+skipped)) jobs ran: an environment was certified, not a tree"
else verdict=pass; why="$passed passed, 0 failed, ${skipped:-0} skipped"; fi
if [ -n "$reason" ]; then verdict=fail; why="$reason"; fi

# Bind the claim to what a re-run can compare against: which gate script ran
# (its blob), which tree, and the RESULT verbatim. On a single-principal box a
# forger can post a status directly; this makes claims reproducible, not forgery-proof.
gate_blob="$(git rev-parse "$sha:ops/local-ci.sh" 2>/dev/null | cut -c1-12)"
tree="$(git rev-parse "$sha^{tree}" 2>/dev/null | cut -c1-12)"
printf '{"sha":"%s","tree":"%s","verdict":"%s","scope":"%s","passed":"%s","failed":"%s","skipped":"%s","gate_blob":"%s","result_line":"%s","why":"%s","recorded_at":"%s","host":"%s"}\n' \
  "$sha" "${tree:-}" "$verdict" "$scope" "${passed:-}" "${failed:-}" "${skipped:-}" "${gate_blob:-}" \
  "$(printf '%s' "$line" | tr -d '"' | cut -c1-200)" "$(printf '%s' "$why" | tr -d '"' | cut -c1-160)" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" > "$dir/$sha.json" 2>/dev/null || true
[ "$verdict" = pass ]
