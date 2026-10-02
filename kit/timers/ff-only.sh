#!/usr/bin/env bash
# Keep the shared checkout at origin/main with --ff-only, and nothing else.
# Refuses (exit 0, logs REFUSE) on tracked changes, wrong branch, divergence, or index.lock.
# An untracked file does not block, except one the merge would overwrite: that makes the merge
# fail, which is logged as FAIL with git's reason (exit 1); --dry-run cannot see it. A failed
# fetch is a FAIL too, with the reason. Log lines: NOOP, FF, WOULD_FF (dry run), REFUSE, FAIL.
# Never resets, never pulls, never touches a serve tree. Self-test builds a throwaway
# upstream and proves the dry run, the fast-forward, the refusals and the failed-fetch reason.
set -euo pipefail
TREE="${KIT_FF_TREE:-$HOME/app}"
REMOTE="${KIT_FF_REMOTE:-origin}"
BRANCH="${KIT_FF_BRANCH:-main}"
LOG="${KIT_FF_LOG:-$HOME/.local/state/ff-only.log}"
DRY=0; SELFTEST=0
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --self-test) SELFTEST=1;; *) echo "usage: ff-only.sh [--dry-run] [--self-test]" >&2; exit 2;; esac; done
log()    { mkdir -p "$(dirname "$LOG")"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
refuse() { log "REFUSE tree=$TREE $*"; exit 0; }
fail()   { log "FAIL tree=$TREE $*"; exit 1; }

# mutate:off  (the self-test is test code: a test of this script cannot check it, and weakening it leaves it passing)
if [[ $SELFTEST -eq 1 ]]; then
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  git init -q -b main "$d/upstream"; git -C "$d/upstream" config user.email t@t; git -C "$d/upstream" config user.name t
  echo a >"$d/upstream/f"; git -C "$d/upstream" add f; git -C "$d/upstream" commit -q -m a
  git clone -q "$d/upstream" "$d/shared"; git -C "$d/upstream" commit -q --allow-empty -m b
  e="KIT_FF_TREE=$d/shared KIT_FF_LOG=$d/log"
  env $e "$0" --dry-run | grep -q WOULD_FF || { echo "self-test: dry-run failed"; exit 1; }
  env $e "$0" >/dev/null || { echo "self-test: ff failed"; exit 1; }
  [[ "$(git -C "$d/shared" rev-parse HEAD)" == "$(git -C "$d/upstream" rev-parse HEAD)" ]] || { echo "self-test: not at tip"; exit 1; }
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  git -C "$d/upstream" commit -q --allow-empty -m c; before="$(git -C "$d/shared" rev-parse HEAD)"
  lock="$(git -C "$d/shared" rev-parse --absolute-git-dir)/index.lock"; : >"$lock"
  ( cd / && env $e "$self" >/dev/null ) || { echo "self-test: an index.lock must refuse with exit 0 whatever the cwd"; exit 1; }
  [[ "$(git -C "$d/shared" rev-parse HEAD)" == "$before" ]] || { echo "self-test: advanced despite an index.lock"; exit 1; }
  grep -q 'REFUSE.*index.lock' "$d/log" || { echo "self-test: the index.lock refusal was not logged"; exit 1; }
  rm -f "$lock"; env $e "$self" >/dev/null || { echo "self-test: fast-forward after the lock cleared failed"; exit 1; }
  echo dirty >"$d/shared/f"; env $e "$0" >/dev/null || { echo "self-test: dirty must refuse with exit 0"; exit 1; }
  grep -q REFUSE "$d/log" || { echo "self-test: dirty not logged"; exit 1; }
  git -C "$d/shared" checkout -q -- f
  # a large dirty tree: the old `status | grep -q` died of SIGPIPE here and fell through to a fast-forward
  mkdir -p "$d/upstream/big"; for i in $(seq 1 3000); do echo "$i" >"$d/upstream/big/a-file-with-a-rather-long-name-to-fill-the-pipe-$i"; done
  git -C "$d/upstream" add big; git -C "$d/upstream" commit -q -m big
  env $e "$self" >/dev/null || { echo "self-test: fast-forward to the commit holding many files failed"; exit 1; }
  git -C "$d/upstream" commit -q --allow-empty -m after-big
  for i in $(seq 1 3000); do echo changed >"$d/shared/big/a-file-with-a-rather-long-name-to-fill-the-pipe-$i"; done
  before="$(git -C "$d/shared" rev-parse HEAD)"
  env $e "$self" >/dev/null || { echo "self-test: a large dirty tree must refuse with exit 0"; exit 1; }
  [[ "$(git -C "$d/shared" rev-parse HEAD)" == "$before" ]] || { echo "self-test: advanced a large dirty tree"; exit 1; }
  git -C "$d/shared" checkout -q -- .   # the throwaway clone only: clear the large dirty tree so the fetch is reached
  env $e KIT_FF_REMOTE=no-such-remote "$self" >/dev/null 2>&1 && { echo "self-test: a failing fetch must exit non-zero"; exit 1; }
  grep -q 'FAIL.*fetch rejected: .' "$d/log" || { echo "self-test: a failed fetch must log its reason"; exit 1; }
  gs() { git -c user.name=t -c user.email=t@t -C "$d/shared" "$@"; }
  gs checkout -q -b side; env $e "$self" >/dev/null || { echo "self-test: a wrong branch must refuse with exit 0"; exit 1; }
  grep -q 'REFUSE.*branch=side' "$d/log" || { echo "self-test: the wrong-branch refusal was not logged"; exit 1; }
  gs checkout -q main; env $e "$self" >/dev/null || { echo "self-test: catching up before the ahead case failed"; exit 1; }
  gs commit -q --allow-empty -m local-only; env $e "$self" >/dev/null || { echo "self-test: a tree ahead of the remote must refuse with exit 0"; exit 1; }
  grep -q 'REFUSE.*ahead' "$d/log" || { echo "self-test: the ahead refusal was not logged"; exit 1; }
  git -C "$d/upstream" commit -q --allow-empty -m newer; env $e "$self" >/dev/null || { echo "self-test: a diverged tree must refuse with exit 0"; exit 1; }
  grep -q 'REFUSE.*diverged' "$d/log" || { echo "self-test: the diverged refusal was not logged"; exit 1; }
  [[ "$(git -C "$d/shared" rev-parse HEAD)" != "$(git -C "$d/upstream" rev-parse HEAD)" ]] || { echo "self-test: a diverged tree was moved"; exit 1; }
  echo "self-test: ok"; exit 0
fi
# mutate:on

[[ -d "$TREE/.git" || -f "$TREE/.git" ]] || fail "not a git checkout"
[[ ! -e "$(git -C "$TREE" rev-parse --absolute-git-dir)/index.lock" ]] || refuse "index.lock"
cd "$TREE"
cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo DETACHED)"
[[ "$cur" == "$BRANCH" ]] || refuse "branch=$cur want=$BRANCH"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || refuse "tracked_dirty"   # no pipe into grep -q: SIGPIPE under pipefail once let a large dirty tree through
err="$(git -c core.hooksPath=/dev/null fetch --quiet "$REMOTE" "$BRANCH" 2>&1)" || fail "fetch rejected: $(printf '%s' "$err" | head -3 | tr '\n' ' ' | sed -E 's#(://)[^/@ ]*@#\1#g')"   # never log a password embedded in a remote URL
local_sha="$(git rev-parse HEAD)"; remote_sha="$(git rev-parse "$REMOTE/$BRANCH")"
[[ "$local_sha" == "$remote_sha" ]] && { log "NOOP already=$local_sha"; exit 0; }
if git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
  [[ $DRY -eq 1 ]] && { log "WOULD_FF $local_sha -> $remote_sha"; exit 0; }
  # no hooks: with a relative core.hooksPath (the installer sets one) the hooks of the tree being merged TO would run unattended
  err="$(git -c core.hooksPath=/dev/null merge --ff-only "$REMOTE/$BRANCH" 2>&1)" || fail "ff-only rejected: $(printf '%s' "$err" | head -3 | tr '\n' ' ')"
  now="$(git rev-parse HEAD)"; [[ "$now" == "$remote_sha" ]] || fail "post-ff HEAD=$now want=$remote_sha"
  log "FF $local_sha -> $now"; exit 0
fi
git merge-base --is-ancestor "$remote_sha" "$local_sha" && refuse "ahead local=$local_sha remote=$remote_sha"
refuse "diverged local=$local_sha remote=$remote_sha"
