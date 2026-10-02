#!/usr/bin/env bash
# Point this clone at the versioned hooks. Run once in each clone and each worktree.
# The hooks must already be committed at kit/hooks/ in this repo (same path). A worktree only has
# what is committed, so installing before the hooks are merged leaves it pointing at nothing.
# Refuses to replace hooks you already have: an existing core.hooksPath, or active hooks in
# .git/hooks, would be orphaned. KIT_FORCE_HOOKS=1 overrides, after you have looked.
# The path is relative, so the hooks that run are those of the commit that is checked out: a branch
# you did not write brings its own kit/hooks/. Do not check out a branch you do not trust in a clone
# that has run this; use `git -c core.hooksPath=/dev/null checkout <branch>`.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
for h in pre-commit pre-push; do
  [ -f "$root/kit/hooks/$h" ] || {
    echo "install-githooks: $root/kit/hooks/$h is missing. Copy kit/hooks/ to kit/hooks/ in this repo (same path), commit it, then retry. Nothing was changed." >&2
    exit 1
  }
done
old="$(git -C "$root" config --get core.hooksPath || true)"
if [ -n "$old" ] && [ "$old" != "kit/hooks" ] && [ "${KIT_FORCE_HOOKS:-0}" != 1 ]; then
  echo "install-githooks: core.hooksPath is already '$old'; installing would replace it. Nothing was changed. KIT_FORCE_HOOKS=1 to proceed." >&2; exit 1
fi
common="$(git -C "$root" rev-parse --git-common-dir)"
active="$(find "$common/hooks" -maxdepth 1 -type f -perm -u+x ! -name '*.sample' 2>/dev/null | head -3 || true)"
if [ -n "$active" ] && [ "${KIT_FORCE_HOOKS:-0}" != 1 ]; then
  echo "install-githooks: $common/hooks already holds active hooks; pointing core.hooksPath elsewhere would silently orphan them:" >&2
  printf '  %s\n' $active >&2
  echo "Nothing was changed. KIT_FORCE_HOOKS=1 to proceed." >&2; exit 1
fi
chmod +x "$root"/kit/hooks/pre-commit "$root"/kit/hooks/pre-push
git -C "$root" config core.hooksPath kit/hooks
echo "hooks installed: $(git -C "$root" config core.hooksPath)"
