#!/usr/bin/env bash
# Minimal local gate that honors the RESULT contract. Copy to ops/local-ci.sh
# and add jobs. Each job is a function; register it with its path filter.
#
# Contract (read by gate-record.sh and the pre-push hook):
#   prints exactly one line:  RESULT: <passed> passed, <failed> failed, <skipped> skipped
#   exit 0 when nothing failed (a run that ran nothing still exits 0; the
#   recorder is what refuses it, on purpose: read the line, not only the exit code)
#
# Path filtering: without --all, a job runs only if the diff against the base
# touches one of its paths. Green on an unchanged tree is worth nothing; a
# merge needs --all (gate-attest.sh --run does that for you).
# A job returns 0 pass, 1 fail, 2 skip (tool absent). Skips are counted, never hidden.
set -uo pipefail
# The jobs below read git paths relative to the current directory. Run from a subdirectory they would
# check only that subtree and still print a green RESULT, so always work from the repository root.
top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "local-ci: not inside a git repository; cannot run" >&2; exit 2; }
cd "$top" || exit 2
ALL=0; [[ "${1:-}" == "--all" ]] && ALL=1
BASE="${KIT_GATE_BASE:-origin/main}"   # set KIT_GATE_BASE if your default branch is not main
if [[ $ALL -eq 1 ]]; then
  changed=ALL
elif changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null)"; then
  echo "gate: filtering against $BASE"
else
  changed=ALL; echo "gate: base $BASE is not usable here, so every job runs (set KIT_GATE_BASE to your default branch)"
fi
passed=0; failed=0; skipped=0
touches() { [[ $ALL -eq 1 || "$changed" == ALL ]] && return 0; [[ -n "$changed" ]] || return 1; for p in "$@"; do grep -qE "^$p" <<<"$changed" && return 0; done; return 1; }
run_job() {  # run_job <name> <fn> <path-regex>...
  local name="$1" fn="$2"; shift 2
  if ! touches "$@"; then echo "⏭️  SKIP $name (no matching paths)"; skipped=$((skipped+1)); return; fi
  "$fn"; local rc=$?
  case $rc in 0) echo "✅ PASS $name"; passed=$((passed+1));; 2) echo "⏭️  SKIP $name (tool absent)"; skipped=$((skipped+1));; *) echo "❌ FAIL $name"; failed=$((failed+1));; esac
}

# ---- jobs (edit below) -------------------------------------------------------
job_shell_syntax() { local f rc=0; while IFS= read -r f; do bash -n "$f" || rc=1; done < <(git ls-files '*.sh' 'kit/hooks/*' 2>/dev/null); return $rc; }
job_shellcheck()   { command -v shellcheck >/dev/null || return 2; git ls-files '*.sh' | xargs -r shellcheck -S warning; }
job_python()       { command -v python3 >/dev/null || return 2; git ls-files '*.py' | xargs -r python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]'; }
job_conflict_markers() { ! git grep -qE '^(<{7} |>{7} )' -- . ':(exclude)test.sh'; }
job_kit_selftest() { [[ -x ./test.sh && "${KIT_IN_SELFTEST:-0}" != 1 ]] || return 2; KIT_IN_SELFTEST=1 ./test.sh >/dev/null; }

run_job shell-syntax job_shell_syntax '.*\.sh$' 'kit/hooks/'
run_job shellcheck   job_shellcheck   '.*\.sh$' 'kit/hooks/'
run_job python       job_python       '.*\.py$'
run_job conflict-markers job_conflict_markers '.*'   # matches every push, so a docs-only change still runs a job
run_job kit-selftest job_kit_selftest 'kit/' 'test\.sh' 'scan\.sh' 'denylist\.generic\.txt' 'export-public\.sh'
# ------------------------------------------------------------------------------
echo "RESULT: $passed passed, $failed failed, $skipped skipped"
[[ $failed -eq 0 ]]
