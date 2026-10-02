#!/usr/bin/env bash
# Build a publishable snapshot of this repo in a NEW directory: one commit, the
# current tree only, no history.
#
# Why this exists: flipping a repo from private to public publishes every commit
# it ever had. If anything sensitive was ever committed (this kit's own denylist
# was, privately), deleting it from the tree does not help. A snapshot has no
# past to leak.
#
# Usage: ./export-public.sh [--identity "Name <email>"] [--head <rev>] [--repo owner/name] <new-dir>
#   - builds from HEAD, so the tree must be clean and committed; --head <rev> refuses unless
#     HEAD is that commit, so the commit you reviewed is the commit you export
#   - the snapshot commit is PUBLIC, so its author and committer are explicit: --identity, or
#     KIT_EXPORT_IDENTITY, or your git identity ONLY when its email is a GitHub noreply address.
#     Any other ambient identity is refused, never silently published. The commit is never signed:
#     a signature would embed your key identity.
#   - KIT_EXPORT_MESSAGE sets the commit subject (default "public snapshot");
#     KIT_EXPORT_TRAILER adds a trailer line (for example a Co-Authored-By) to the commit message
#   - needs your local denylist (KIT_DENYLIST_LOCAL); without it the gate cannot attest
#   - refuses to run while KIT_ALLOW_BINARY or KIT_ALLOW_GENERIC_ONLY is set: those weaken the gate
#   - must sit at the repository root
#   - runs the tree scan, the history scan (which also reads commit headers, tags, refs and file
#     names), and the snapshot's own test.sh INSIDE the new directory
#   - checks the snapshot's tree is identical to HEAD, so export-ignore/export-subst cannot change it
#   - needs a test.sh in the snapshot (KIT_EXPORT_NO_TEST=1 skips that, for a repo without one)
#   - never creates a remote and never pushes; on success it prints one command that checks the
#     snapshot is still exactly the commit it built, scans it again, and only then publishes it to
#     the repository named in $REPO. --repo owner/name prints the REPO= line ready to paste.
# Exit: 0 ready, 1 a gate refused, 2 cannot run.
set -euo pipefail
callerdir="$PWD"   # a relative target means relative to where the caller stands, not to this script
cd "$(dirname "$0")"
here="$PWD"
# Read the repository this script sits in, not whatever the caller's environment points at.
while read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars 2>/dev/null)
export GIT_NO_REPLACE_OBJECTS=1
ident="${KIT_EXPORT_IDENTITY:-}"; target=""; want=""; have_head=0; pubrepo=""
usage() { echo "usage: export-public.sh [--identity \"Name <email>\"] [--head <rev>] [--repo owner/name] <new-dir>" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) [[ $# -ge 2 ]] || usage; ident="$2"; shift 2 ;;
    --head) [[ $# -ge 2 ]] || usage; want="$2"; have_head=1; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || usage; pubrepo="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$target" ]] || usage; target="$1"; shift ;;
  esac
done
[[ -n "$target" ]] || usage
[[ $have_head -eq 0 || -n "$want" ]] || usage   # --head '' must not quietly switch the pin off
for v in "$ident" "$target" "${KIT_EXPORT_MESSAGE:-}" "${KIT_EXPORT_TRAILER:-}"; do
  [[ ! "$v" =~ [[:cntrl:]] ]] || { echo "export: the identity, target, message and trailer must not contain control characters" >&2; exit 2; }
done
if [[ -n "$pubrepo" && ! "$pubrepo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then echo "export: --repo must look like owner/name" >&2; exit 2; fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "export: not a git repository" >&2; exit 2; }
[[ "$(pwd -P)" == "$(git rev-parse --show-toplevel)" ]] || { echo "export: this script must sit at the repository root; run from a subdirectory it would export only that directory" >&2; exit 2; }
for var in KIT_ALLOW_BINARY KIT_ALLOW_GENERIC_ONLY; do
  [[ "${!var:-0}" == 0 ]] || { echo "export: $var is set. It weakens the leak gate, and an export is exactly where that must not happen. Unset it and retry." >&2; exit 2; }
done
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "export: uncommitted changes. The snapshot is built from HEAD; commit first." >&2; exit 2
fi
git rev-parse --verify -q HEAD >/dev/null || { echo "export: this repository has no commits; nothing to export" >&2; exit 2; }
src_head="$(git rev-parse HEAD)"; src_tree="$(git rev-parse 'HEAD^{tree}')"
if [[ -n "$want" ]]; then
  wanted="$(git rev-parse --verify -q "$want^{commit}" || true)"
  [[ -n "$wanted" && "$wanted" == "$src_head" ]] || { echo "export: HEAD is ${src_head:0:12}, not the commit you asked for ($want). Check out the reviewed commit and retry." >&2; exit 2; }
fi
tgt="$(cd "$callerdir" && python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target")" || { echo "export: cannot resolve $target" >&2; exit 2; }   # not realpath -m: that is GNU only
case "$tgt/" in "$here"/*) echo "export: the target must be outside this repository" >&2; exit 2 ;; esac
if [[ -e "$tgt" && -n "$(ls -A "$tgt" 2>/dev/null)" ]]; then echo "export: $tgt exists and is not empty" >&2; exit 2; fi

nr="users.noreply.github.com"   # built from a variable so this file never contains an email-shaped string
if [[ -z "$ident" ]]; then
  n="$(git config user.name || true)"; e="$(git config user.email || true)"
  if [[ -n "$n" && "$e" == *"@$nr" ]]; then
    ident="$n <$e>"
  else
    echo "export: the snapshot commit is PUBLIC. Your ambient git identity is not a GitHub noreply address, so it is not used." >&2
    echo "        Pass --identity 'Name <you@$nr>' (or set KIT_EXPORT_IDENTITY)." >&2; exit 2
  fi
fi
re='^[^<>]+ <[^<> @]+@[^<> @]+>$'
[[ "$ident" =~ $re ]] || { echo "export: the identity must look like: Name <email>" >&2; exit 2; }
name="${ident%% <*}"; email="${ident##* <}"; email="${email%>}"

# Fail early, before building anything, if the gate could not attest anyway.
[[ -f "${KIT_DENYLIST_LOCAL:-$HOME/.config/battleship-kit/denylist.txt}" ]] || {
  echo "export: no local denylist; the leak gate cannot attest. Create one (see scan.sh) and retry." >&2; exit 2; }

msg="${KIT_EXPORT_MESSAGE:-public snapshot}"
[[ -z "${KIT_EXPORT_TRAILER:-}" ]] || msg="$msg

$KIT_EXPORT_TRAILER"

# The snapshot is built from the commit named above, never from whatever HEAD is by the time git runs,
# and with none of the caller's git configuration, hooks or templates: a global hook or an excludes file
# could otherwise put text into the public commit or drop files from it.
isolated() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
build() {
  mkdir -p "$tgt"
  git archive --format=tar "$src_head" | tar -x -C "$tgt"
  isolated -C "$tgt" init -q -b main --template=
  isolated -C "$tgt" add -A
  # explicit author and committer, and no signing whatever the ambient config says
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
    isolated -C "$tgt" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false -c i18n.commitEncoding=UTF-8 commit -q --no-verify -m "$msg"
}
build || { echo "export: could not build the snapshot in $tgt (git or tar failed); nothing was published" >&2; exit 2; }
snap="$(git -C "$tgt" rev-parse HEAD)"
[[ "$(git -C "$tgt" log -1 --format=%B)" == "$msg" ]] || { echo "export: the snapshot commit message is not the one asked for. Refusing; nothing was published." >&2; exit 2; }
# The snapshot must be EXACTLY the reviewed tree. git archive honors export-ignore, export-subst and
# $GIT_DIR/info/attributes, which can drop or rewrite files, so the two trees are compared.
if ! diff <(git ls-tree -r "$src_head") <(git -C "$tgt" ls-tree -r HEAD) >/dev/null; then
  echo "export: the snapshot's tree differs from the source commit (export-ignore, export-subst or an attributes file changed what was archived). Refusing; nothing was published." >&2; exit 2
fi
[[ "$(git rev-parse HEAD)" == "$src_head" ]] || { echo "export: HEAD moved while the snapshot was being built. Nothing was published; run it again." >&2; exit 2; }
echo "export: source commit ${src_head:0:12}, tree ${src_tree:0:12}"
echo "export: snapshot built in $tgt: $(git -C "$tgt" ls-files | wc -l) files, 1 commit ${snap:0:12} by $name, tree identical to the source; running the gates there"

rc=0
( cd "$tgt" && KIT_REQUIRE_LOCAL=1 ./scan.sh && KIT_REQUIRE_LOCAL=1 ./scan.sh --history ) || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "export: a scan refused the snapshot (exit $rc). Fix the tree, commit, and export again into a NEW directory." >&2
  exit $(( rc == 2 ? 2 : 1 ))
fi
if [[ -x "$tgt/test.sh" ]]; then
  ( cd "$tgt" && ./test.sh >/dev/null 2>&1 ) || { echo "export: the snapshot's own test.sh failed; run it in $tgt to see why" >&2; exit 1; }
  echo "export: the snapshot passes its own test.sh"
elif [[ "${KIT_EXPORT_NO_TEST:-0}" == 1 ]]; then
  echo "export: no test.sh in the snapshot; skipped (KIT_EXPORT_NO_TEST=1)"
else
  echo "export: the snapshot has no executable test.sh, and a snapshot nobody can test is not READY (KIT_EXPORT_NO_TEST=1 skips this)." >&2; exit 2
fi
echo "export: READY. Nothing has been published. Do not edit $tgt: change the source, commit, and export again."
if [[ -n "$pubrepo" ]]; then echo "Set the target repository, then publish:"; echo "  REPO='$pubrepo'"; else echo "Set the target repository first (owner/name, for example REPO=you/the-kit), then publish:"; fi
echo "This one command stops unless REPO is set, the snapshot is still commit ${snap:0:12} with a clean tree, and a rescan with your local list required is clean; only then does it publish:"
printf '  ( cd %s && unset KIT_ALLOW_BINARY KIT_ALLOW_GENERIC_ONLY && export KIT_REQUIRE_LOCAL=1 && [[ "${REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [ "$(git rev-parse HEAD)" = %s ] && st="$(git status --porcelain --untracked-files=normal --ignore-submodules=none)" && [ -z "$st" ] && [ "$(git rev-list --count HEAD)" = 1 ] && ./scan.sh && ./scan.sh --history && gh repo create "$REPO" --public --source=. --push )\n' "$(printf '%q' "$tgt")" "$snap"
if [[ -f "$tgt/ESSAY.md" ]]; then echo "ESSAY.md speaks in the first person. Read it, and be sure every statement in it is yours, before you publish."; fi
exit 0
