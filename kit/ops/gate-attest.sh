#!/usr/bin/env bash
# Publish a recorded gate outcome as the `local-ci/gate` commit status.
#
# Only an --all run can attest a MERGE. A path-filtered run says nothing about
# the rest of the tree, so a filtered pass publishes PENDING, not success. A
# skipped or failed gate publishes FAILURE on purpose, so the emergency override
# cannot produce a quietly mergeable branch.
#
# Usage: gate-attest.sh [sha]      publish the record for that commit
#        gate-attest.sh --run      run the full gate, record it, publish it
# --run exists because otherwise the weakest link moves instead of closing: the
# deliberate extra step is the one skipped under exactly the time pressure that
# produced 3-second merges. One command, or it is the honour system again.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--run" ]; then
  [ -n "${KIT_GATE_REPO:-}" ] || { echo "gate-attest: set KIT_GATE_REPO=owner/repo before running the gate. Cannot attest." >&2; exit 2; }
  top="$(git rev-parse --show-toplevel)"; sha="$(git rev-parse HEAD)"
  cd "$top" || exit 2
  # explicit flags: status.showUntrackedFiles=no or status.ignoreSubmodules in a config must not switch the refusal off
  if [ -n "$(git status --porcelain --untracked-files=normal --ignore-submodules=none)" ]; then
    echo "gate-attest: the working tree is not clean (uncommitted changes or untracked files); the gate would test code that is not in $sha. Commit, stash, ignore or remove them, then retry." >&2; exit 2
  fi
  [ -x "$top/ops/local-ci.sh" ] || { echo "gate-attest: $top/ops/local-ci.sh is missing or not executable. Cannot attest." >&2; exit 2; }
  echo "gate-attest: running the FULL gate (--all)." >&2
  out="$("$top/ops/local-ci.sh" --all 2>&1)"; rc=$?; printf '%s\n' "$out" | tail -25 >&2
  line="$(printf '%s' "$out" | grep -E '^RESULT:' | tail -1)"
  if [ "$rc" -ne 0 ]; then
    KIT_GATE_RAN_ALL=1 "$here/gate-record.sh" "$sha" all "$line" "gate exited with status $rc" || true
  else
    KIT_GATE_RAN_ALL=1 "$here/gate-record.sh" "$sha" all "$line" || true
  fi
  exec "$here/$(basename "$0")" "$sha"
fi
sha="$(git rev-parse "${1:-HEAD}" 2>/dev/null)" || { echo "gate-attest: not a git sha: ${1:-HEAD}" >&2; exit 2; }
dir="${KIT_GATE_STATE_DIR:-$HOME/.local/state/gate}"; rec="$dir/$sha.json"
[ -n "${KIT_GATE_REPO:-}" ] || { echo "gate-attest: set KIT_GATE_REPO=owner/repo. Cannot attest." >&2; exit 2; }
repo="$KIT_GATE_REPO"
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$rec"; }
[ -f "$rec" ] || { echo "gate-attest: NO RECORD for $sha. The gate did not run on this exact commit on this box." >&2; exit 1; }
verdict="$(field verdict)"; scope="$(field scope)"; why="$(field why)"
if [ "$verdict" = pass ] && [ "$scope" = all ]; then state=success; desc="local-ci --all: $why | gate $(field gate_blob) | tree $(field tree)"
elif [ "$verdict" = pass ]; then state=pending; desc="NOT A PASS - filtered run only ($why), needs --all"
else state=failure; desc="local-ci: $why"; fi
desc="$(printf '%s' "$desc" | cut -c1-138)"
if gh api -X POST "repos/$repo/statuses/$sha" -f state="$state" -f context="local-ci/gate" -f description="$desc" >/dev/null 2>&1; then
  echo "gate-attest: $sha -> $state ($desc)"; [ "$state" = success ] || exit 1
else
  echo "gate-attest: could not publish status for $sha (gh api failed)" >&2; exit 1
fi
