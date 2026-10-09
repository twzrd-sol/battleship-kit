#!/usr/bin/env bash
# The kit tests itself. No network, no gh, no docker needed. Exit 1 on any failure.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
kr="$PWD"
# KIT_TEST_SECTIONS=a,b runs only the sections whose heading contains one of those words (kit/ops/mutate.py uses
# this to test a script against the sections that exercise it). The shared fixtures and the result always run.
if [ -n "${KIT_TEST_SECTIONS:-}" ] && [ -z "${KIT_TEST_SLICED:-}" ]; then
  sliced="$(python3 - "$kr/test.sh" "$KIT_TEST_SECTIONS" <<'PY'
import re, sys
keys = [k for k in sys.argv[2].split(",") if k]
parts = re.split(r'(?m)^(?=echo "== )', open(sys.argv[1]).read())
keep = [p for p in parts[1:] if p.startswith('echo "== result"') or any(k in p.split("\n", 1)[0] for k in keys)]
sys.stdout.write("".join([parts[0]] + keep))
PY
)" || exit 2
  exec env KIT_TEST_SLICED=1 bash -c "$sliced" "$kr/test.sh"
fi
# Every scratch file and directory these tests make lives under ONE root that is removed on exit, so a
# run leaves nothing behind. (A version that cleaned up only the last fixture of each section once
# left thousands of small repositories in a shared /tmp and exhausted its inodes.)
kit_tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$kit_tmp"' EXIT
trap 'exit 2' INT TERM HUP
export TMPDIR="$kit_tmp"
# Ambient git configuration (signing, identity, hooks, templates) must not change a result: use an empty HOME.
mkdir -p "$kit_tmp/home"; export HOME="$kit_tmp/home" XDG_CONFIG_HOME="$kit_tmp/home/.config" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# ---- shared fixtures: every section below is independent, so a section can be run alone (KIT_TEST_SECTIONS) ----
# A throwaway local list: never your real one, never a real identifier.
KIT_DENYLIST_LOCAL="$(mktemp)"; export KIT_DENYLIST_LOCAL
printf '%s-%s\n' acme internal-host > "$KIT_DENYLIST_LOCAL"
nr="$(printf '%s@%s' t users.noreply.github.com)"   # a GitHub noreply identity, built at runtime so this file holds no email-shaped string
idf="$(printf '%s-%s' acme internal-host)"          # the throwaway local-list identifier
export KIT_EXPORT_NO_TEST=1   # the fixture repos below have no test.sh; one test turns this off
unset KIT_EXPORT_MESSAGE KIT_EXPORT_TRAILER   # an exporter run with a trailer set runs this suite: its nested exports must not inherit the caller's
unset KIT_REQUIRE_LOCAL KIT_ALLOW_GENERIC_ONLY KIT_ALLOW_BINARY   # the scanner's switches: inherited from a caller's shell they turn the generic-only and empty-list checks red (seen 2026-10-09)
export KIT_GATE_STATE_DIR; KIT_GATE_STATE_DIR="$(mktemp -d)"; sha="$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"
mk() { local d; d="$(mktemp -d)"; git init -q -b main "$d"; cp scan.sh denylist.generic.txt "$d/"; git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email="$nr" commit -q -m base; echo "$d"; }
scanrc() { ( cd "$1" && ./scan.sh "${@:2}" >"$1/.scanout" 2>&1 ); echo $?; }
sgit() { git -C "$1" -c user.name=t -c user.email="$nr" "${@:2}"; }
ld="$(mktemp -d)"   # pattern lists live OUTSIDE the scanned tree, so a test cannot pass by finding its own list
# ---------------------------------------------------------------------------------------------------------------
export PYTHONDONTWRITEBYTECODE=1   # the tests must never leave bytecode in the tree they are testing
export KIT_IN_SELFTEST=1   # local-ci.sh skips its self-test job when run from here (no recursion)
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); [ "${KIT_TEST_FAILFAST:-0}" = 1 ] && exit 1; return 0; }   # KIT_TEST_FAILFAST=1: stop at the first failure (kit/ops/mutate.py uses it)

echo "== syntax"
for f in scan.sh test.sh kit/hooks/pre-commit kit/hooks/pre-push kit/hooks/install-githooks.sh kit/timers/ff-only.sh kit/ops/*.sh; do
  bash -n "$f" && ok "$f" || bad "$f"; done
python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' kit/ops/*.py && ok "python parses" || bad "python parses"
if command -v shellcheck >/dev/null; then shellcheck -S warning kit/hooks/* kit/timers/ff-only.sh kit/ops/*.sh scan.sh test.sh && ok shellcheck || bad shellcheck; else echo "  skip shellcheck (not installed)"; fi

echo "== leak gate"
./scan.sh >/dev/null 2>&1 && ok "clean tree passes (generic + throwaway local list)" || bad "clean tree passes"
printf 'contact: %s@%s.example\n' jane corp > .planted.md; ./scan.sh >/dev/null 2>&1; rc=$?; rm -f .planted.md
[ $rc -eq 1 ] && ok "planted email refused by the generic list" || bad "planted email refused (exit $rc)"
printf 'host: %s-%s\n' acme internal-host > .planted.md; out="$(./scan.sh 2>&1)"; rc=$?; rm -f .planted.md
[ $rc -eq 1 ] && ok "planted local-list identifier refused" || bad "planted local-list identifier refused (exit $rc)"
if printf '%s' "$out" | grep -q "$(printf '%s-%s' acme internal-host)"; then bad "scan output leaked the local pattern or the matched text"; else ok "scan output names file:line only, never a local pattern or matched text"; fi
KIT_REQUIRE_LOCAL=1 KIT_DENYLIST_LOCAL=/nonexistent ./scan.sh >/dev/null 2>&1; [ $? -eq 2 ] && ok "a required but missing local list cannot attest" || bad "required local list missing"
KIT_DENYLIST_LOCAL=/nonexistent ./scan.sh >/dev/null 2>&1; [ $? -eq 2 ] && ok "a missing local list refuses by default" || bad "missing local list refuses by default"
out="$(KIT_ALLOW_GENERIC_ONLY=1 KIT_DENYLIST_LOCAL=/nonexistent ./scan.sh 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q WARNING && ok "KIT_ALLOW_GENERIC_ONLY=1 scans with the generic patterns and says so" || bad "KIT_ALLOW_GENERIC_ONLY (exit $rc)"
KIT_REQUIRE_LOCAL=1 KIT_ALLOW_GENERIC_ONLY=1 KIT_DENYLIST_LOCAL=/nonexistent ./scan.sh >/dev/null 2>&1; [ $? -eq 2 ] && ok "KIT_REQUIRE_LOCAL=1 overrides KIT_ALLOW_GENERIC_ONLY=1" || bad "REQUIRE overrides ALLOW"
printf 'x\n' > .planted.md; printf '%s\n' '[#][0-9]{3,4}' > "$KIT_DENYLIST_LOCAL.t"; printf 'see %s%s\n' '#' 4321 > .planted.md
KIT_DENYLIST_LOCAL="$KIT_DENYLIST_LOCAL.t" ./scan.sh >/dev/null 2>&1; rc=$?; rm -f .planted.md "$KIT_DENYLIST_LOCAL.t"
[ $rc -eq 1 ] && ok "a pattern written [#]... is live (a line starting with # is a comment)" || bad "[#] pattern (exit $rc)"
printf '%s\n' '(' > "$KIT_DENYLIST_LOCAL.bad"
KIT_DENYLIST_LOCAL="$KIT_DENYLIST_LOCAL.bad" ./scan.sh >/dev/null 2>&1; [ $? -eq 2 ] && ok "an invalid local pattern cannot attest (it used to read as clean)" || bad "invalid local pattern"
printf '%s-%s\r\n' acme internal-host > "$KIT_DENYLIST_LOCAL.crlf"; printf 'host: %s-%s\n' acme internal-host > .planted.md
KIT_DENYLIST_LOCAL="$KIT_DENYLIST_LOCAL.crlf" ./scan.sh >/dev/null 2>&1; rc=$?; rm -f .planted.md
[ $rc -eq 1 ] && ok "a CRLF local list still catches its identifiers" || bad "CRLF local list (exit $rc)"
printf '# nothing\n' > "$KIT_DENYLIST_LOCAL.empty"
KIT_REQUIRE_LOCAL=1 KIT_DENYLIST_LOCAL="$KIT_DENYLIST_LOCAL.empty" ./scan.sh >/dev/null 2>&1; [ $? -eq 2 ] && ok "an empty local list cannot attest when required" || bad "empty required local list"
rm -f "$KIT_DENYLIST_LOCAL".bad "$KIT_DENYLIST_LOCAL".crlf "$KIT_DENYLIST_LOCAL".empty

echo "== history gate and snapshot export"
h="$(mktemp -d)"; git init -q -b main "$h/src"; git -C "$h/src" config user.name t; git -C "$h/src" config user.email "$nr"; cp scan.sh export-public.sh denylist.generic.txt "$h/src/"
g() { git -C "$h/src" -c user.name=t -c user.email="$nr" "$@"; }
g add -A; g commit -q -m base
printf 'host: %s\n' "$idf" > "$h/src/notes.md"; g add -A; g commit -q -m leak
g rm -q notes.md; g commit -q -m "remove the leak"
( cd "$h/src" && ./scan.sh >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "tree scan passes once the leak is deleted" || bad "tree scan after deleting the leak"
( cd "$h/src" && ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "history scan still refuses: the leak lives in an old commit" || bad "history scan refuses an old leak"
( cd "$h/src" && ./export-public.sh "$h/out" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "export builds a snapshot" || bad "export builds a snapshot"
[ "$(git -C "$h/out" rev-list --count HEAD 2>/dev/null)" = 1 ] && ok "the snapshot is one commit" || bad "the snapshot is one commit"
[ "$(git -C "$h/out" log -1 --format='%an <%ae>' 2>/dev/null)" = "t <$nr>" ] && ok "the snapshot is authored by the noreply identity" || bad "snapshot author"
( cd "$h/out" && ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "the snapshot's history is clean" || bad "the snapshot's history is clean"
( cd "$h/src" && KIT_DENYLIST_LOCAL=/nonexistent ./export-public.sh "$h/out2" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export refuses without a local denylist" || bad "export refuses without a local denylist"
echo "# edit" >> "$h/src/scan.sh"; ( cd "$h/src" && ./export-public.sh "$h/out3" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export refuses a dirty tree" || bad "export refuses a dirty tree"
git -C "$h/src" checkout -q -- scan.sh
( cd "$h/src" && ./export-public.sh "$h/src/inside" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export refuses a target inside the repo" || bad "export refuses a target inside the repo"
git -C "$h/src" config user.email t@t
( cd "$h/src" && ./export-public.sh "$h/outA" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export refuses an ambient identity that is not a noreply address" || bad "ambient identity"
( cd "$h/src" && ./export-public.sh --identity "Pub Lic <$nr>" "$h/outB" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "export accepts an explicit identity" || bad "explicit identity"
[ "$(git -C "$h/outB" log -1 --format='%an|%ae|%cn|%ce' 2>/dev/null)" = "Pub Lic|$nr|Pub Lic|$nr" ] && ok "author and committer are both the explicit identity" || bad "author and committer identity"
( cd "$h/src" && KIT_EXPORT_TRAILER='Co-Authored-By: Kit Test' ./export-public.sh --identity "Pub Lic <$nr>" "$h/outC" >/dev/null 2>&1 ); git -C "$h/outC" log -1 --format=%B 2>/dev/null | grep -q 'Co-Authored-By: Kit Test' && ok "the optional trailer reaches the commit message" || bad "trailer"
( cd "$h/src" && ./export-public.sh --identity "not an identity" "$h/outD" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "a malformed identity is refused" || bad "malformed identity"
git -C "$h/src" config user.email "$nr"
( cd "$h/src" && env -u KIT_EXPORT_NO_TEST ./export-public.sh "$h/outF" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "a snapshot with no test.sh is not READY" || bad "export without test.sh"
printf 'scan.sh export-ignore\n' > "$h/src/.gitattributes"; g add -A; g commit -q -m "attrs"
( cd "$h/src" && ./export-public.sh "$h/outG" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export-ignore cannot silently shrink the snapshot: the trees are compared" || bad "export-ignore"
g reset -q --hard HEAD~1
printf '%s\n' '$Format:%H$' > "$h/src/README"; printf 'README export-subst\n' > "$h/src/.gitattributes"; g add -A; g commit -q -m "subst"
( cd "$h/src" && ./export-public.sh "$h/outH" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export-subst cannot rewrite files in the snapshot" || bad "export-subst"
g reset -q --hard HEAD~1
printf '%s-%s\n' acme internal-host >> "$h/src/denylist.generic.txt"; g add -A; g commit -q -m "hide an identifier in the shipped list"
( cd "$h/src" && ./scan.sh >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "a real identifier hidden in the shipped list is caught by the local patterns" || bad "identifier hidden in the shipped list"
git -C "$h/src" reset -q --hard HEAD~1
printf 'x\n' > "$h/src/denylist.local.txt"; git -C "$h/src" add -f denylist.local.txt
( cd "$h/src" && ./scan.sh >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "a tracked local denylist is refused" || bad "tracked local denylist"
rm -rf "$h"

echo "== exporter: refusal paths, signing, binding, the printed publish command"
x="$(mktemp -d)"; git init -q -b main "$x/src"; cp scan.sh export-public.sh denylist.generic.txt "$x/src/"
xg() { git -C "$x/src" -c user.name=t -c user.email="$nr" "$@"; }
xg add -A; xg commit -q -m base
xid="Pub Lic <$nr>"
xexp() { ( cd "$x/src" && "$@" ) >"$x/out.txt" 2>&1; echo $?; }   # run in the source; the exit code is printed, the output stays in $x/out.txt
printf 'host: %s\n' "$idf" > "$x/src/notes.md"; xg add -A; xg commit -q -m notes
[ "$(xexp ./export-public.sh --identity "$xid" "$x/o1")" = 1 ] && grep -q 'a scan refused' "$x/out.txt" && ok "export exits 1 when a scan finds a local-list identifier in the snapshot" || bad "export leak refusal"
xg rm -q notes.md; xg commit -q -m "remove notes"
[ "$(xexp ./export-public.sh --identity "$idf <$nr>" "$x/o2")" = 1 ] && ok "export exits 1 when the identity itself is a local-list identifier (the history scan reads the author)" || bad "export identity refusal"
[ "$(KIT_ALLOW_GENERIC_ONLY=1 xexp ./export-public.sh --identity "$xid" "$x/o3")" = 2 ] && grep -q 'KIT_ALLOW_GENERIC_ONLY' "$x/out.txt" && ok "export refuses to run with KIT_ALLOW_GENERIC_ONLY set, and names it" || bad "ambient KIT_ALLOW_GENERIC_ONLY"
[ "$(KIT_ALLOW_BINARY=1 xexp ./export-public.sh --identity "$xid" "$x/o4")" = 2 ] && grep -q 'KIT_ALLOW_BINARY' "$x/out.txt" && ok "export refuses to run with KIT_ALLOW_BINARY set, and names it" || bad "ambient KIT_ALLOW_BINARY"
printf '%s\n' '(' > "$x/bad.pats"
[ "$(KIT_DENYLIST_LOCAL="$x/bad.pats" xexp ./export-public.sh --identity "$xid" "$x/o5")" = 2 ] && ok "export exits 2 when the local list cannot be used" || bad "export with an unusable list"
printf '#!/bin/sh\n[ "$(git rev-list --count HEAD)" = 1 ]\n' > "$x/src/test.sh"; chmod +x "$x/src/test.sh"; xg add -A; xg commit -q -m "a test that must run inside the snapshot"
[ "$(unset KIT_EXPORT_NO_TEST; xexp ./export-public.sh --identity "$xid" "$x/o6")" = 0 ] && grep -q 'passes its own test.sh' "$x/out.txt" && ok "the snapshot's own test.sh runs inside the snapshot and passes" || bad "snapshot test.sh passing"
printf '#!/bin/sh\nexit 1\n' > "$x/src/test.sh"; xg add -A; xg commit -q -m "a failing test"
[ "$(unset KIT_EXPORT_NO_TEST; xexp ./export-public.sh --identity "$xid" "$x/o7")" = 1 ] && grep -q 'own test.sh failed' "$x/out.txt" && ok "a failing snapshot test.sh stops the export (exit 1)" || bad "snapshot test.sh failing"
printf '#!/bin/sh\n[ "$(git rev-list --count HEAD)" = 1 ]\n' > "$x/src/test.sh"; xg add -A; xg commit -q -m "a passing test again"
printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n' > "$x/gpg.cfg"
[ "$(GIT_CONFIG_GLOBAL="$x/gpg.cfg" xexp ./export-public.sh --identity "$xid" "$x/o8")" = 0 ] && ok "export succeeds even when ambient config says to sign commits with an unusable signer" || bad "export under a signing config"
[ "$(git -C "$x/o8" cat-file commit HEAD | grep -c '^gpgsig')" = 0 ] && ok "and the public commit carries no signature" || bad "snapshot commit is signed"
mkdir -p "$x/src/ops/scripts"; git -C "$x/src" mv export-public.sh scan.sh denylist.generic.txt ops/scripts/; xg commit -q -m "moved"
( cd "$x/src/ops/scripts" && ./export-public.sh --identity "$xid" "$x/o9" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "export refuses to run from a subdirectory: it would export only that directory" || bad "export from a subdirectory"
git -C "$x/src" mv ops/scripts/export-public.sh ops/scripts/scan.sh ops/scripts/denylist.generic.txt . ; xg commit -q -m "moved back"
[ "$(xexp ./export-public.sh --identity "$xid" --head HEAD~1 "$x/o10")" = 2 ] && grep -q 'not the commit you asked for' "$x/out.txt" && ok "--head refuses unless HEAD is the commit you asked for" || bad "--head mismatch"
[ "$(unset KIT_EXPORT_NO_TEST; xexp ./export-public.sh --identity "$xid" --head "$(git -C "$x/src" rev-parse HEAD)" "$x/o11")" = 0 ] && ok "--head accepts the commit that is HEAD" || bad "--head match"
src12="$(git -C "$x/src" rev-parse HEAD | cut -c1-12)"; tree12="$(git -C "$x/src" rev-parse 'HEAD^{tree}' | cut -c1-12)"
grep -q "source commit $src12, tree $tree12" "$x/out.txt" && ok "READY names the source commit and tree it was built from" || bad "READY does not name the source"
grep -q 'ESSAY' "$x/out.txt" && bad "an ESSAY line was printed for a repo with no ESSAY.md" || ok "the ESSAY reminder appears only when the snapshot has an ESSAY.md"
[ "$(git -C "$x/o11" log -1 --format=%s)" = "public snapshot" ] && ok "the default commit subject is generic" || bad "default subject"
[ "$(unset KIT_EXPORT_NO_TEST; KIT_EXPORT_MESSAGE='my subject' xexp ./export-public.sh --identity "$xid" "$x/o12")" = 0 ] && [ "$(git -C "$x/o12" log -1 --format=%s)" = "my subject" ] && ok "KIT_EXPORT_MESSAGE sets the subject" || bad "KIT_EXPORT_MESSAGE"
mkdir -p "$x/badtar"; printf '#!/bin/sh\nexit 1\n' > "$x/badtar/tar"; chmod +x "$x/badtar/tar"
[ "$(PATH="$x/badtar:$PATH" xexp ./export-public.sh --identity "$xid" "$x/o13")" = 2 ] && ok "a failure while building the snapshot exits 2, not a raw git status" || bad "build failure exit"
# the printed command: it must refuse a snapshot that was changed after READY
mkdir -p "$x/fakebin"; printf '#!/bin/sh\necho "$@" >> "%s/gh.log"\n' "$x/fakebin" > "$x/fakebin/gh"; chmod +x "$x/fakebin/gh"
xexp env -u KIT_EXPORT_NO_TEST ./export-public.sh --identity "$xid" "$x/o14" >/dev/null
chain="$(grep '^  ( cd ' "$x/out.txt" | sed 's/^  //')"
chain_run() {   # chain_run [VAR=value ...]: runs the printed command with a fake gh; prints "<exit>:published|held"
  rm -f "$x/fakebin/gh.log"; ( env REPO=acme/pub "$@" PATH="$x/fakebin:$PATH" bash -c "$chain" >/dev/null 2>&1 ); local rc=$?
  if [ -f "$x/fakebin/gh.log" ]; then echo "$rc:published"; else echo "$rc:held"; fi
}
[ "$(chain_run FOO=1)" = "0:published" ] && grep -q 'gh repo create "$REPO"' "$x/out.txt" && ok "the printed command publishes an untouched snapshot to the repository named in REPO (against a fake gh)" || bad "printed command on an untouched snapshot"
rm -f "$x/fakebin/gh.log"; ( env -u REPO PATH="$x/fakebin:$PATH" bash -c "$chain" >/dev/null 2>&1 ); r1=$?; g1=0; [ -f "$x/fakebin/gh.log" ] && g1=1
rm -f "$x/fakebin/gh.log"; ( env REPO='not a repo' PATH="$x/fakebin:$PATH" bash -c "$chain" >/dev/null 2>&1 ); r2=$?; g2=0; [ -f "$x/fakebin/gh.log" ] && g2=1
{ [ $r1 -ne 0 ] && [ $g1 = 0 ] && [ $r2 -ne 0 ] && [ $g2 = 0 ]; } && ok "and it refuses, without calling gh, when REPO is unset or is not owner/name" || bad "printed command without a usable REPO ($r1 $g1 $r2 $g2)"
[ "$(chain_run KIT_ALLOW_GENERIC_ONLY=1 KIT_DENYLIST_LOCAL=/nonexistent)" != "0:published" ] && ok "and it holds when the environment tries to drop the local list" || bad "printed command with an ambient weakener"
echo '# changed after READY' >> "$x/o14/test.sh"
[ "$(chain_run FOO=1)" = "1:held" ] && ok "and it holds when a tracked file was edited after READY" || bad "printed command after an edit"
git -C "$x/o14" checkout -q -- test.sh; : > "$x/o14/stray.txt"; git -C "$x/o14" config status.showUntrackedFiles no
[ "$(chain_run FOO=1)" = "1:held" ] && ok "and when an untracked file appeared, even with status.showUntrackedFiles=no" || bad "printed command with an untracked file"
rm -f "$x/o14/stray.txt"; echo '# benign amend' >> "$x/o14/test.sh"; git -C "$x/o14" add -A; git -C "$x/o14" -c user.name=t -c user.email="$nr" commit -q --amend --no-edit
[ "$(chain_run FOO=1)" = "1:held" ] && ok "and when the snapshot commit was amended: the scans alone would pass this, the pinned commit id does not" || bad "printed command after an amend"
( cd / && "$x/src/export-public.sh" --identity "$xid" "$x/abs" >"$x/out.txt" 2>&1 ); [ $? -eq 0 ] && grep -q 'READY' "$x/out.txt" && grep -q 'This one command stops unless REPO is set' "$x/out.txt" && ok "it works when started by absolute path from another directory, and says READY and how to publish" || bad "export from another directory"
{ [ "$(grep -n 'scan: clean (the working tree' "$x/out.txt" | cut -d: -f1)" -lt "$(grep -n 'scan: clean (every commit' "$x/out.txt" | cut -d: -f1)" ]; } && grep -qE 'snapshot built in .*: [0-9]+ files, 1 commit [0-9a-f]{12} by Pub Lic, tree identical' "$x/out.txt" && ok "and it runs the tree scan then the history scan, and reports what it built" || bad "export output"
( cd "$x/src" && ./export-public.sh >"$x/out.txt" 2>&1 ); r1=$?; grep -q usage "$x/out.txt" || r1=99
( cd "$x/src" && ./export-public.sh --bogus "$x/o20" >"$x/out.txt" 2>&1 ); r2=$?; grep -q usage "$x/out.txt" || r2=99
( cd "$x/src" && ./export-public.sh --identity "$xid" >"$x/out.txt" 2>&1 ); r3=$?; grep -q usage "$x/out.txt" || r3=99
( cd "$x/src" && ./export-public.sh --bogus >"$x/out.txt" 2>&1 ); r4=$?; grep -q '^usage: export-public.sh' "$x/out.txt" || r4=99
( cd "$x/src" && ./export-public.sh --identity "$xid" --repo 'no slash' "$x/o28" >"$x/out.txt" 2>&1 ); r5=$?; grep -q -- '--repo must look like owner/name' "$x/out.txt" || r5=99
[ "$r5" = 2 ] && ok "--repo must look like owner/name" || bad "--repo validation ($r5)"
( cd "$x/src" && ./export-public.sh --identity "$xid" --repo acme/pub "$x/o29" >"$x/out.txt" 2>&1 ); grep -q "^  REPO='acme/pub'" "$x/out.txt" && ok "--repo prints the REPO line ready to paste" || bad "--repo line"
[ "$r1$r2$r3$r4" = 2222 ] && ok "no target, an unknown flag, or a flag with no target is a usage error (exit 2)" || bad "export usage ($r1 $r2 $r3 $r4)"
mkdir -p "$x/plain"; cp "$kr/export-public.sh" "$x/plain/"; ( cd "$x/plain" && ./export-public.sh --identity "$xid" "$x/o21" >"$x/out.txt" 2>&1 ); [ $? -eq 2 ] && grep -q '^export: not a git repository' "$x/out.txt" && ok "outside a git repository it cannot run (exit 2)" || bad "export outside a repository"
mkdir -p "$x/src/ops/scripts"; cp "$kr/export-public.sh" "$x/src/ops/scripts/"
( cd "$x/src/ops/scripts" && ./export-public.sh --identity "$xid" "$x/o22" >"$x/out.txt" 2>&1 ); [ $? -eq 2 ] && grep -q 'must sit at the repository root' "$x/out.txt" && ok "from a subdirectory it says why it refuses" || bad "export subdirectory message"
rm -rf "$x/src/ops"
mkdir -p "$x/o23"; ( cd "$x/src" && ./export-public.sh --identity "$xid" "$x/o23" >"$x/out.txt" 2>&1 ); r1=$?
mkdir -p "$x/o24"; : > "$x/o24/file"; ( cd "$x/src" && ./export-public.sh --identity "$xid" "$x/o24" >"$x/out.txt" 2>&1 ); r2=$?
{ [ $r1 = 0 ] && [ $r2 = 2 ] && grep -q 'is not empty' "$x/out.txt"; } && ok "an existing empty directory is a fine target; a non-empty one is refused (exit 2)" || bad "export target directory ($r1 $r2)"
xp="$(mktemp -d)"; for tool in bash git grep sed env cat tr cut head tail sort wc dirname basename mkdir rm mktemp uname awk find ls tar diff date; do ln -s "$(command -v $tool)" "$xp/$tool" 2>/dev/null; done
( cd "$x/src" && PATH="$xp" ./export-public.sh --identity "$xid" "$x/o25" >"$x/out.txt" 2>&1 ); [ $? -eq 2 ] && grep -q 'cannot resolve' "$x/out.txt" && ok "a machine without python3 cannot run it, and it says so (exit 2)" || bad "export without python3"
git -C "$x/src" config user.email "$(printf '%s%s%s' dev '@' 'work.invalid')"; git -C "$x/src" config user.name Dev
( cd "$x/src" && GIT_CONFIG_GLOBAL=/dev/null ./export-public.sh "$x/o26" >"$x/out.txt" 2>&1 ); r1=$?
{ [ $r1 = 2 ] && grep -q 'is PUBLIC' "$x/out.txt" && grep -q 'noreply' "$x/out.txt" && grep -q -- '--identity' "$x/out.txt"; } && ok "an ambient identity that is not a noreply address is refused with the way out" || bad "ambient identity message ($r1)"
git -C "$x/src" config --unset user.email; git -C "$x/src" config --unset user.name
xr="$(mktemp -d)"; git init -q -b main "$xr"; cp scan.sh export-public.sh denylist.generic.txt "$xr/"; printf 'host: %s\n' "$idf" > "$xr/leak.md"; git -C "$xr" add -A; git -C "$xr" -c user.name=t -c user.email="$nr" commit -q -m leak
cleanb="$(printf 'clean\n' | git -C "$xr" hash-object -w --stdin)"; git -C "$xr" replace "$(git -C "$xr" rev-parse HEAD:leak.md)" "$cleanb"
( cd "$xr" && ./export-public.sh --identity "$xid" "$x/o27" >"$x/out.txt" 2>&1 ); [ $? -eq 1 ] && ok "a refs/replace entry cannot swap a leaking file for a clean one in the snapshot: the real objects are exported and refused" || bad "export with a replace ref"
( cd "$x/src" && ./export-public.sh --identity "$xid" --head '' "$x/o30" >"$x/out.txt" 2>&1 ); r1=$?; grep -q '^usage:' "$x/out.txt" || r1=99
[ "$r1" = 2 ] && ok "an empty --head is a usage error, not a pin that quietly turned itself off" || bad "--head '' ($r1)"
xlate="$(mktemp -d)"; printf '#!/bin/bash\nif [ "$1" = archive ]; then %s -C "%s" -c user.name=t -c user.email="%s" commit -q --allow-empty -m late; fi\nexec %s "$@"\n' "$(command -v git)" "$x/src" "$nr" "$(command -v git)" > "$xlate/git"; chmod +x "$xlate/git"
( cd "$x/src" && PATH="$xlate:$PATH" ./export-public.sh --identity "$xid" "$x/o31" >"$x/out.txt" 2>&1 ); r1=$?
{ [ $r1 = 2 ] && grep -q 'HEAD moved' "$x/out.txt"; } && ok "a commit that lands while the snapshot is built is not exported under the old commit's name (exit 2)" || bad "HEAD moved during export ($r1)"
mkdir -p "$x/hooks"; printf '#!/bin/sh\necho "Injected-Line: yes" >> "$1"\n' > "$x/hooks/commit-msg"; chmod +x "$x/hooks/commit-msg"; printf '[core]\n\thooksPath = %s\n\texcludesFile = %s\n' "$x/hooks" "$x/excl" > "$x/hook.cfg"; printf '*.md\n' > "$x/excl"
( cd "$x/src" && GIT_CONFIG_GLOBAL="$x/hook.cfg" ./export-public.sh --identity "$xid" "$x/o32" >"$x/out.txt" 2>&1 ); r1=$?
{ [ $r1 = 0 ] && [ "$(git -C "$x/o32" log -1 --format=%B)" = "public snapshot" ] && [ "$(git -C "$x/o32" ls-files | wc -l)" = "$(git -C "$x/src" ls-files | wc -l)" ]; } && ok "the caller's global hooks and excludes file cannot put text into the public commit or drop files from it" || bad "ambient hooks and excludes ($r1)"
inj="$x/inj'; touch $x/PWNED; echo '"; mkdir -p "$inj"
( cd "$x/src" && ./export-public.sh --identity "$xid" "$inj/out" >"$x/out.txt" 2>&1 ); r1=$?
chain2="$(grep '^  ( cd ' "$x/out.txt" | sed 's/^  //')"; ( env REPO=acme/pub PATH="$x/fakebin:$PATH" bash -c "$chain2" >/dev/null 2>&1 )
{ [ $r1 = 0 ] && [ ! -e "$x/PWNED" ]; } && ok "a target path with quotes and semicolons is quoted in the printed command and runs nothing else" || bad "path injection ($r1)"
( cd "$x/src" && ./export-public.sh --identity "$(printf 'Eve\033[31m') <$nr>" "$x/o33" >"$x/out.txt" 2>&1 ); r1=$?
{ [ $r1 = 2 ] && grep -q 'control characters' "$x/out.txt"; } && ok "a control character in the identity is refused, not echoed to the terminal" || bad "control character in identity ($r1)"
( cd "$x" && "$x/src/export-public.sh" --identity "$xid" reltarget >"$x/out.txt" 2>&1 ); r1=$?
{ [ $r1 = 0 ] && [ -d "$x/reltarget/.git" ]; } && ok "a relative target is relative to where you stand, not to the script" || bad "relative target ($r1)"
xe="$(mktemp -d)"; git init -q -b main "$xe"; cp scan.sh export-public.sh denylist.generic.txt "$xe/"
( cd "$xe" && ./export-public.sh --identity "$xid" "$x/o34" >"$x/out.txt" 2>&1 ); r1=$?; { [ $r1 = 2 ] && grep -q 'no commits' "$x/out.txt"; } && ok "a repository with no commits exits 2 with a plain message" || bad "no commits ($r1)"
( cd "$x/src" && ./export-public.sh --identity "$xid" "$x/o35" >"$x/out.txt" 2>&1 ); chain3="$(grep '^  ( cd ' "$x/out.txt" | sed 's/^  //')"
printf 'junk' > "$x/o35/.git/index"; rm -f "$x/fakebin/gh.log"; ( env REPO=acme/pub PATH="$x/fakebin:$PATH" bash -c "$chain3" >/dev/null 2>&1 ); r1=$?
{ [ $r1 -ne 0 ] && [ ! -f "$x/fakebin/gh.log" ]; } && ok "a damaged index in the snapshot holds the printed command instead of passing its clean-tree test" || bad "corrupt index ($r1)"
rm -rf "$x"

echo "== scan reads what git stores besides contents"
m="$(mk)"; git -C "$m" -c user.name=t -c user.email="$nr" commit -q --allow-empty -m "notes about $idf"
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a commit message is caught" || bad "identifier in a commit message"
if grep -q "$idf" "$m/.scanout"; then bad "the scan output repeated the identifier"; else ok "and the output does not repeat it"; fi
m="$(mk)"; git -C "$m" -c user.name="$idf" -c user.email="$nr" commit -q --allow-empty -m x
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a commit author name is caught" || bad "identifier in an author name"
m="$(mk)"; git -C "$m" branch "feat/$idf"
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a branch name is caught" || bad "identifier in a branch name"
m="$(mk)"; printf 'x\n' > "$m/$idf.txt"; git -C "$m" add -A; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "add a file"
[ "$(scanrc "$m")" = 1 ] && ok "an identifier in a file name is caught by the tree scan" || bad "identifier in a file name (tree)"
git -C "$m" rm -q "$idf.txt"; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "remove it"
[ "$(scanrc "$m")" = 0 ] && ok "the tree is clean once the file is gone" || bad "tree clean after removing the file"
[ "$(scanrc "$m" --history)" = 1 ] && ok "but the history still holds the file name and refuses" || bad "history file name"
m="$(mk)"; git -C "$m" -c user.name=Pub -c user.email="$nr" commit -q --allow-empty -m "published by the noreply identity"
[ "$(scanrc "$m" --history)" = 0 ] && ok "a GitHub noreply identity is not a hit" || bad "noreply identity flagged"
m="$(mk)"; sgit "$m" checkout -q -b side; printf 'host: %s\n' "$idf" > "$m/leak.md"; git -C "$m" add -A; sgit "$m" commit -q -m leak; sgit "$m" checkout -q main
[ "$(scanrc "$m" --history)" = 1 ] && ok "a leak that only another branch holds is caught: every ref is read, not just the checked-out one" || bad "leak on another branch"
m="$(mk)"; sgit "$m" checkout -q -b gone; printf 'host: %s\n' "$idf" > "$m/leak.md"; git -C "$m" add -A; sgit "$m" commit -q -m leak; sgit "$m" tag onlytag; sgit "$m" checkout -q main; git -C "$m" branch -q -D gone
[ "$(scanrc "$m" --history)" = 1 ] && ok "and one that only a tag reaches" || bad "leak reachable only from a tag"
m="$(mk)"; git -C "$m" -c user.name=t -c user.email="$(printf '%s%s%s' "$idf" '@' 'host.invalid')" commit -q --allow-empty -m x
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a commit author email is caught" || bad "author email"
m="$(mk)"; GIT_COMMITTER_NAME="$idf" git -C "$m" -c user.name=t -c user.email="$nr" commit -q --allow-empty -m x
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a committer name is caught" || bad "committer name"
m="$(mk)"; GIT_COMMITTER_EMAIL="$(printf '%s%s%s' "$idf" '@' 'host.invalid')" git -C "$m" -c user.name=t -c user.email="$nr" commit -q --allow-empty -m x
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a committer email is caught" || bad "committer email"
m="$(mk)"; git -C "$m" -c user.name=t -c user.email="$nr" commit -q --allow-empty -m "subject" -m "body mentions $idf"
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a commit message body, not just its subject, is caught" || bad "commit body"
m="$(mk)"; git -C "$m" tag "rel-$idf"
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a lightweight tag name is caught" || bad "tag name"
m="$(mk)"; printf '\xef\xbb\xbf' | cat - "$m/denylist.generic.txt" > "$m/g.tmp"; mv "$m/g.tmp" "$m/denylist.generic.txt"
[ "$(scanrc "$m")" = 2 ] && grep -q 'shipped list cannot be trusted' "$m/.scanout" && ok "a shipped list with a byte-order mark is refused, like a local one" || bad "shipped list lint"
printf '# nothing yet\n' > "$ld/empty.pats"; m="$(mk)"
( cd "$m" && KIT_ALLOW_GENERIC_ONLY=1 KIT_DENYLIST_LOCAL="$ld/empty.pats" ./scan.sh >"$m/.scanout" 2>&1 ); r1=$?
( cd "$m" && KIT_REQUIRE_LOCAL=1 KIT_ALLOW_GENERIC_ONLY=1 KIT_DENYLIST_LOCAL="$ld/empty.pats" ./scan.sh >/dev/null 2>&1 ); r2=$?
{ [ $r1 = 0 ] && grep -q 'WARNING' "$m/.scanout" && [ $r2 = 2 ]; } && ok "an empty local list passes only with KIT_ALLOW_GENERIC_ONLY=1 and a warning, and KIT_REQUIRE_LOCAL=1 overrides that" || bad "empty local list modes ($r1 $r2)"
m="$(mk)"; ln -s /etc/hostname "$m/link"
[ "$(scanrc "$m")" = 1 ] && grep -q 'symbolic link' "$m/.scanout" && ok "a symbolic link refuses the tree scan (its target is never read)" || bad "symlink in the tree"
rm -f "$m/link"; printf '\x00 binary \xff' > "$m/blob.dat"
[ "$(scanrc "$m")" = 1 ] && grep -q 'binary file' "$m/.scanout" && ok "a binary file refuses the tree scan" || bad "binary file in the tree"
( cd "$m" && KIT_ALLOW_BINARY=1 ./scan.sh >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "and KIT_ALLOW_BINARY=1 is the explicit, human-inspected exception" || bad "KIT_ALLOW_BINARY"
printf 'i\x00d\x00 \x00' > "$m/blob.dat"; git -C "$m" add -A; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "add binary"; git -C "$m" rm -q blob.dat; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "remove it"
[ "$(scanrc "$m")" = 0 ] && ok "a deleted binary file leaves the tree clean" || bad "tree clean after deleting a binary file"
[ "$(scanrc "$m" --history)" = 1 ] && grep -q 'binary file' "$m/.scanout" && ok "but the history still holds it and refuses" || bad "binary file in history"
m="$(mk)"; printf '*.txt -diff\n' > "$m/.gitattributes"
[ "$(scanrc "$m")" = 1 ] && grep -q 'gitattributes' "$m/.scanout" && ok "a .gitattributes that can hide text refuses the scan" || bad ".gitattributes"
ga_ok=1
for kw in export-ignore export-subst -diff -text binary filter=x ident; do
  m="$(mk)"; mkdir -p "$m/sub/deep"; printf '*.md %s\n' "$kw" > "$m/sub/deep/.gitattributes"
  { [ "$(scanrc "$m")" = 1 ] && grep -q 'gitattributes' "$m/.scanout"; } || { ga_ok=0; echo "  not refused in a nested .gitattributes: $kw"; }
done
[ $ga_ok -eq 1 ] && ok "every .gitattributes keyword that can hide or rewrite text refuses the tree scan, in a subdirectory too" || bad "a .gitattributes keyword was accepted"
for kw in export-subst filter=x; do
  m="$(mk)"; mkdir -p "$m/sub"; printf '*.md %s\n' "$kw" > "$m/sub/.gitattributes"; git -C "$m" add -A; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m attrs
  git -C "$m" rm -q sub/.gitattributes; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "remove attrs"
  { [ "$(scanrc "$m")" = 0 ] && [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'gitattributes' "$m/.scanout"; } && ok "a nested .gitattributes ($kw) deleted later still refuses the history scan" || bad "history .gitattributes $kw"
done
m="$(mk)"; ln -s /etc/hostname "$m/link"; git -C "$m" add -A; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "add a link"; git -C "$m" rm -q link; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "remove it"
{ [ "$(scanrc "$m")" = 0 ] && [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'symbolic link' "$m/.scanout"; } && ok "a symbolic link deleted later still refuses the history scan" || bad "symlink in history"
m="$(mk)"; git -C "$m" update-index --add --cacheinfo 160000,"$(git -C "$m" rev-parse HEAD)",vendored
{ [ "$(scanrc "$m")" = 1 ] && grep -q 'submodule' "$m/.scanout"; } && ok "a submodule entry refuses the tree scan: its content is not part of this repository" || bad "submodule in the tree"
git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "add a submodule entry"; git -C "$m" rm -q --cached vendored; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "remove it"
{ [ "$(scanrc "$m")" = 0 ] && [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'submodule' "$m/.scanout"; } && ok "and a submodule deleted later still refuses the history scan" || bad "submodule in history"
m="$(mk)"; git -C "$m" -c user.name=t -c user.email="$(printf '%s+x@%s' "$idf" users.noreply.github.com)" commit -q --allow-empty -m "by a handle that is an identifier"
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in the local part of a noreply address is still caught" || bad "identifier in a noreply local part"
m="$(mk)"; head -c 100000 /dev/zero | tr '\0' a > "$m/long.txt"; git -C "$m" add -A; git -C "$m" -c user.name=t -c user.email="$nr" commit -q -m "one long line"
( cd "$m" && timeout 120 ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "a 100 KB single line does not hang the history scan" || bad "long line hangs or fails the history scan"
mu="$(mk)"; printf 'm\xc3\xbcller\n' > "$ld/list.pats"; printf 'x M\xc3\x9cLLER y\n' > "$mu/note.txt"
( cd "$mu" && LC_ALL=C KIT_DENYLIST_LOCAL="$ld/list.pats" ./scan.sh >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "non-ASCII case folding does not depend on the caller's locale" || bad "locale dependence"
lst() { printf "$1" > "$ld/l.pats"; ( cd "$mu" && KIT_DENYLIST_LOCAL="$ld/l.pats" ./scan.sh >"$mu/.scanout" 2>&1 ); echo $?; }
rm -f "$mu/note.txt"
[ "$(lst '\xef\xbb\xbfacme-x\n')" = 2 ] && ok "a local list with a byte-order mark is refused, not half-read" || bad "BOM list"
[ "$(lst 'acme-x\x00\n')" = 2 ] && ok "a local list with NUL bytes is refused" || bad "NUL list"
[ "$(lst 'acme-\xff\xfe\n')" = 2 ] && ok "a local list that is not valid UTF-8 is refused" || bad "invalid UTF-8 list"
[ "$(lst 'acme-x # a note\n')" = 2 ] && ok "a local pattern with an inline comment is refused" || bad "inline comment"
[ "$(lst '# only comments\n\n')" = 2 ] && ok "a local list with no active patterns cannot attest" || bad "empty local list"
[ "$(lst 'acme-\\d{3}\n')" = 2 ] && ok "a PCRE escape such as \\d is refused instead of silently reading as a literal d" || bad "PCRE escape"
[ "$(lst 'zorb\\x67lax\n')" = 2 ] && ok "\\x67 is refused: grep -E reads it as a plain letter, so the pattern would check something else" || bad "hex escape"
[ "$(lst 'acme\\twidgets\n')" = 2 ] && ok "\\t is refused for the same reason" || bad "tab escape"
[ "$(lst 'C:\\Users\\bob\n')" = 2 ] && ok "a Windows path with single backslashes is refused (\\U reads as a letter)" || bad "windows path"
[ "$(lst 'acme-\\\\d\n')" = 0 ] && ok "an escaped backslash followed by a letter is a legal pattern" || bad "escaped backslash"
[ "$(lst '\\bacme-word\\b\n')" = 0 ] && ok "word-boundary escapes (\\b) stay legal" || bad "word boundary escape"
[ "$(lst 'acme-one\racme-two\r')" = 2 ] && ok "a list with bare carriage returns is refused: grep would read it as one pattern" || bad "bare CR list"
[ "$(lst 'acme-one\xe2\x80\xa8acme-two\n')" = 2 ] && ok "a list with a Unicode line separator is refused" || bad "U+2028 list"
[ "$(lst 'x*\n')" = 2 ] && grep -q 'empty line' "$mu/.scanout" && ok "a pattern that matches an empty line is refused: it would hit every file" || bad "empty-matching pattern"
eng_ok=1; for pat in '+a' '*a' 'a{1'; do [ "$(lst "$pat\n")" = 2 ] && grep -q 'not usable as a POSIX ERE' "$mu/.scanout" || { eng_ok=0; echo "  accepted: $pat"; }; done
[ $eng_ok -eq 1 ] && ok "a pattern that grep -E accepts but git grep -E rejects is unusable too, because history is searched with git grep" || bad "second regex engine"
[ "$(lst '^\n')" = 2 ] && ok "so is a bare anchor" || bad "bare anchor"
printf 'x acme-trailing y\n' > "$mu/note.txt"
[ "$(lst 'acme-trailing   \n')" = 1 ] && ok "trailing whitespace on a local pattern is trimmed, not silently fatal to the match" || bad "trailing whitespace"
rm -rf "$mu" "$m"

echo "== scan completeness: what git ships besides file contents"
m="$(mk)"; sgit "$m" tag -a v1 -m "release notes for $idf"
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in an annotated tag message is caught" || bad "tag message"
m="$(mk)"; git -C "$m" -c user.name="$idf" -c user.email="$nr" tag -a v1 -m clean
[ "$(scanrc "$m" --history)" = 1 ] && ok "an identifier in a tagger name is caught" || bad "tagger name"
m="$(mk)"; sgit "$m" tag -a inner -m "inner notes $idf"; innersha="$(git -C "$m" rev-parse refs/tags/inner)"; sgit "$m" tag -d inner >/dev/null
outer="$(printf 'object %s\ntype tag\ntag outer\ntagger t <%s> 1700000000 +0000\n\nouter is clean\n' "$innersha" "$nr" | git -C "$m" hash-object -t tag -w --stdin --literally)"; git -C "$m" update-ref refs/tags/outer "$outer"
{ [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'HIT local #1 in history metadata' "$m/.scanout"; } && ok "an identifier in a tag that only another tag points at is read, not merely refused" || bad "nested tag"
m="$(mk)"; csha="$(git -C "$m" rev-parse HEAD)"
st="$(printf 'object %s\ntype commit\ntag signed\ntagger t <%s> 1700000000 +0000\n\nrelease\n-----BEGIN PGP SIGNATURE-----\n\nabc\n-----END PGP SIGNATURE-----\n' "$csha" "$nr" | git -C "$m" hash-object -t tag -w --stdin --literally)"; git -C "$m" update-ref refs/tags/signed "$st"
[ "$(scanrc "$m" --history)" = 1 ] && grep -q 'signed tags' "$m/.scanout" && ok "a signed tag is refused: its signature embeds the signer's key identity" || bad "signed tag"
m="$(mk)"; bl="$(printf 'secret\n' | git -C "$m" hash-object -w --stdin)"; git -C "$m" update-ref refs/tags/blobby "$bl"
[ "$(scanrc "$m" --history)" = 1 ] && grep -q 'not a commit' "$m/.scanout" && ok "a ref that points at a blob is refused: that content ships and is not scanned" || bad "ref to a blob"
m="$(mk)"; ctree="$(git -C "$m" rev-parse 'HEAD^{tree}')"; cpar="$(git -C "$m" rev-parse HEAD)"
hc="$(printf 'tree %s\nparent %s\nauthor t <%s> 1700000000 +0000\ncommitter t <%s> 1700000000 +0000\nx-note %s\n\nmsg\n' "$ctree" "$cpar" "$nr" "$nr" "$idf" | git -C "$m" hash-object -t commit -w --stdin --literally)"; git -C "$m" update-ref refs/heads/hdr "$hc"
[ "$(scanrc "$m" --history)" = 1 ] && grep -q 'HIT local #1 in history metadata' "$m/.scanout" && ok "an identifier in an extra commit header is read" || bad "extra commit header text"
grep -q 'headers other than' "$m/.scanout" && ok "and a commit with such a header is refused on its own" || bad "extra header refusal"
m="$(mk)"; ctree="$(git -C "$m" rev-parse 'HEAD^{tree}')"; cpar="$(git -C "$m" rev-parse HEAD)"
hc="$(printf 'tree %s\nparent %s\nauthor t <%s> 1700000000 +0000\ncommitter t <%s> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\nmsg\n' "$ctree" "$cpar" "$nr" "$nr" | git -C "$m" hash-object -t commit -w --stdin --literally)"; git -C "$m" update-ref refs/heads/sig "$hc"
[ "$(scanrc "$m" --history)" = 1 ] && grep -q 'signed commits' "$m/.scanout" && ok "a signed commit is refused: its signature embeds the signer's key identity" || bad "signed commit"
cafe="caf$(printf '\xc3\xa9')"; printf 'caf\xc3\xa9\n' > "$ld/cafe.pats"
m="$(mk)"; printf 'x\n' > "$m/$cafe.txt"; git -C "$m" add -A; sgit "$m" commit -q -m "add a file with an accent in its name"
( cd "$m" && KIT_DENYLIST_LOCAL="$ld/cafe.pats" ./scan.sh >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "an identifier with an accent in a file name is caught by the tree scan" || bad "accented name (tree)"
sgit "$m" rm -q "$cafe.txt"; sgit "$m" commit -q -m "remove it"
( cd "$m" && KIT_DENYLIST_LOCAL="$ld/cafe.pats" ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "and by the history scan: git does not quote the name before it is read" || bad "accented name (history)"
m="$(mk)"; mkdir -p "$m/other" "$m/docs"; printf 'ok\n' > "$m/docs/ok.md"; printf 'host: %s\n' "$idf" > "$m/other/leak.md"; git -C "$m" add -A; sgit "$m" commit -q -m files
if git -C "$m" sparse-checkout set docs >/dev/null 2>&1; then
  [ "$(scanrc "$m")" = 1 ] && grep -q 'sparse' "$m/.scanout" && ok "a sparse checkout refuses the tree scan: it would miss tracked files that ship" || bad "sparse checkout"
else echo "  skip sparse checkout (this git has no sparse-checkout)"; fi
m="$(mk)"; printf 'host: %s\n' "$idf" > "$m/leak.md"; git -C "$m" add -A; sgit "$m" commit -q -m leak
leakb="$(git -C "$m" rev-parse HEAD:leak.md)"; cleanb="$(printf 'clean\n' | git -C "$m" hash-object -w --stdin)"; git -C "$m" replace "$leakb" "$cleanb"
[ "$(scanrc "$m" --history)" = 1 ] && ok "refs/replace cannot make the history look clean: the scan reads the objects a clone receives" || bad "replace ref"
mr="$(mk)"; hidb="$(printf 'host %s replacement\n' "$idf" | git -C "$mr" hash-object -w --stdin)"; cleanb="$(printf 'clean\n' | git -C "$mr" hash-object -w --stdin)"; git -C "$mr" replace "$cleanb" "$hidb"
{ [ "$(scanrc "$mr" --history)" = 1 ] && grep -q 'replace refs' "$mr/.scanout"; } && ok "a replace ref is refused even when it names an object no commit reaches: a mirror clone would carry it" || bad "replace ref to an unreachable blob"
clean="$(mk)"; ( cd "$m" && GIT_DIR="$clean/.git" ./scan.sh --history >"$m/.scanout" 2>&1 ); [ $? -eq 1 ] && ok "an inherited GIT_DIR cannot point the scan at a different repository" || bad "inherited GIT_DIR"
sh2="$(mktemp -d)"; git clone -q --depth 1 "file://$m" "$sh2/c" 2>/dev/null
( cd "$sh2/c" && ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "a shallow clone cannot attest: the history that ships is not there" || bad "shallow clone"
m="$(mk)"; git -C "$m" rev-parse HEAD > "$m/.git/info/grafts"
[ "$(scanrc "$m" --history)" = 2 ] && ok "a grafts file cannot attest: it rewrites history locally but not in a clone" || bad "grafts file"
m="$(mk)"; mkdir -p "$m/ops/scripts"; git -C "$m" mv scan.sh denylist.generic.txt ops/scripts/ 2>/dev/null; printf 'host: %s\n' "$idf" > "$m/leak.md"; git -C "$m" add -A; sgit "$m" commit -q -m moved
( cd "$m/ops/scripts" && ./scan.sh >/dev/null 2>&1 ); r1=$?; ( cd "$m/ops/scripts" && ./scan.sh --history >/dev/null 2>&1 ); r2=$?
[ "$r1$r2" = 22 ] && ok "scan.sh refuses to run from a subdirectory: it would cover only that directory and read clean" || bad "scan from a subdirectory ($r1$r2)"
echo "== scan completeness: encoding, invisible characters, lists, output"
m="$(mk)"; printf 'caf\xe9 note\n' > "$m/latin1.txt"
[ "$(scanrc "$m")" = 1 ] && grep -q 'not valid UTF-8' "$m/.scanout" && ok "latin-1 text is refused: a pattern cannot read it" || bad "latin-1 file"
( cd "$m" && KIT_ALLOW_BINARY=1 ./scan.sh >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "and KIT_ALLOW_BINARY=1 is the explicit, human-inspected exception" || bad "KIT_ALLOW_BINARY for latin-1"
git -C "$m" add -A; sgit "$m" commit -q -m "add latin-1"; git -C "$m" rm -q latin1.txt; sgit "$m" commit -q -m "remove it"
[ "$(scanrc "$m")" = 0 ] && [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'not valid UTF-8' "$m/.scanout" && ok "a latin-1 file is refused in history too, after it is deleted from the tree" || bad "latin-1 in history"
m="$(mk)"; printf 'host: ac\xe2\x80\x8bme-%s\n' "internal-host" > "$m/note.txt"
[ "$(scanrc "$m")" = 1 ] && grep -q 'invisible' "$m/.scanout" && ok "a zero-width character inside an identifier is refused: it would defeat every pattern" || bad "zero-width in a file"
m="$(mk)"; printf '\xef\xbb\xbfhello\n' > "$m/bom.txt"
[ "$(scanrc "$m")" = 1 ] && grep -q 'invisible' "$m/.scanout" && ok "a byte-order mark inside a file is refused" || bad "BOM in a file"
m="$(mk)"; printf 'x\n' > "$m/ac$(printf '\xe2\x80\x8b')me.txt"
[ "$(scanrc "$m")" = 1 ] && grep -q 'invisible' "$m/.scanout" && ok "a zero-width character in a file name is refused" || bad "zero-width in a name"
m="$(mk)"; sgit "$m" commit -q --allow-empty -m "$(printf 'ac\xe2\x80\x8bme')"
[ "$(scanrc "$m" --history)" = 1 ] && grep -q 'invisible' "$m/.scanout" && ok "a zero-width character in a commit message is refused" || bad "zero-width in a message"
m="$(mk)"; printf 'a\xe2\x80\x8bb\n' > "$m/z.txt"; git -C "$m" add -A; sgit "$m" commit -q -m z; git -C "$m" rm -q z.txt; sgit "$m" commit -q -m rmz
[ "$(scanrc "$m")" = 0 ] && [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'invisible' "$m/.scanout" && ok "and in a file version that was deleted later" || bad "zero-width in history"
m="$(mk)"; printf 'host: %s\n' "$idf" > "$m/$idf-notes.txt"; git -C "$m" add -A; sgit "$m" commit -q -m notes
scanrc "$m" >/dev/null; if grep -q "$idf" "$m/.scanout"; then bad "the tree scan printed a path that holds the identifier"; else ok "a hit's path is withheld when the path itself holds the identifier (tree)"; fi
grep -q 'path withheld' "$m/.scanout" || bad "no withheld marker (tree)"
scanrc "$m" --history >/dev/null; if grep -q "$idf" "$m/.scanout"; then bad "the history scan printed a path that holds the identifier"; else ok "and in history"; fi
sh3="$(mktemp -d)"; mkdir -p "$sh3/a" "$sh3/b"; realgrep="$(command -v grep)"; realgit="$(command -v git)"
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = -raniEZ ] && exit 2; done\nexec %s "$@"\n' "$realgrep" > "$sh3/a/grep"
printf '#!/bin/bash\nif [ "$1" = grep ]; then for a in "$@"; do [ "$a" = -anE ] && exit 2; done; fi\nexec %s "$@"\n' "$realgit" > "$sh3/a/git"
printf '#!/bin/bash\nif [ "$1" = grep ]; then for a in "$@"; do [ "$a" = -c ] && exit 2; done; fi\nexec %s "$@"\n' "$realgit" > "$sh3/b/git"
chmod +x "$sh3"/a/* "$sh3"/b/*
m="$(mk)"
( cd "$m" && PATH="$sh3/a:$PATH" ./scan.sh >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "a grep that fails in the middle of the tree scan cannot read as clean" || bad "failing grep (tree)"
( cd "$m" && PATH="$sh3/a:$PATH" ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "a git grep that fails in the middle of the content scan cannot read as clean" || bad "failing git grep (content)"
( cd "$m" && PATH="$sh3/b:$PATH" ./scan.sh --history >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "and one that fails in a structural check cannot read as clean either" || bad "failing git grep (structure)"
shape() {   # shape <label> <text>: a generic shape the list must refuse
  m="$(mk)"; printf '%s\n' "$2" > "$m/note.txt"
  [ "$(scanrc "$m")" = 1 ] && grep -q 'HIT generic' "$m/.scanout" && ok "the generic list refuses $1" || bad "generic shape: $1"
}
shape "an 88-character base58 secret key" "$(printf '2%.0s' $(seq 1 88))"
shape "64 hexadecimal characters" "$(printf 'ab%.0s' $(seq 1 32))"
shape "a keypair written as a JSON array" "[$(seq -s, 1 64)]"
shape "a JSON web token" "$(printf '%s%s.%s.%s' eyJ hbGciOiJIUzI1NiJ9 eyJzdWIiOiIxMjM0NTY3ODkwIn0 abcdefghij)"
shape "an npm token" "npm_$(printf 'a%.0s' $(seq 1 36))"
shape "an armored PGP private key header" "$(printf '%s %s %s%s' '-----BEGIN' PGP 'PRIVATE KEY' ' BLOCK-----')"
shape "an OpenSSH private key header" "$(printf '%s %s %s%s' '-----BEGIN' OPENSSH 'PRIVATE KEY' '-----')"
for fam in ghp gho ghu ghs ghr; do shape "a GitHub $fam token" "$(printf '%s_%s' "$fam" "$(printf 'a%.0s' $(seq 1 30))")"; done
shape "a GitHub fine-grained token" "$(printf 'github_%s_%s' pat "$(printf 'a%.0s' $(seq 1 30))")"
shape "a Stripe live secret key" "$(printf '%s_%s_%s' sk live "$(printf 'b%.0s' $(seq 1 24))")"
shape "a Stripe restricted key" "$(printf '%s_%s_%s' rk test "$(printf 'b%.0s' $(seq 1 24))")"
shape "a Stripe webhook secret" "$(printf '%s_%s' whsec "$(printf 'c%.0s' $(seq 1 30))")"
shape "a Slack app-level token" "$(printf 'xapp-1-%s-%s' A0123456789 abcdefghij)"
shape "a GitLab personal access token" "$(printf '%s-%s' glpat "$(printf 'd%.0s' $(seq 1 24))")"
shape "a Hugging Face token" "$(printf '%s_%s' hf "$(printf 'e%.0s' $(seq 1 34))")"
shape "a PyPI upload token" "$(printf '%s-%s%s' pypi AgEI "$(printf 'f%.0s' $(seq 1 30))")"
shape "a Google OAuth access token" "$(printf '%s.%s' ya29 "$(printf 'g%.0s' $(seq 1 30))")"
shape "a SendGrid API key" "$(printf '%s.%s.%s' SG "$(printf 'h%.0s' $(seq 1 22))" "$(printf 'i%.0s' $(seq 1 22))")"
shape "a password in a URL with an empty user name" "$(printf '%s%s%s:%s@%s:6379/0' redis '://' '' hunter2hunter2 cache)"
shape "a Slack incoming-webhook URL" "$(printf 'https://hooks.slack.com/services/%s/%s/%s' T0123ABCD B0123ABCD "$(printf 'k%.0s' $(seq 1 24))")"
shape "a Discord webhook URL" "$(printf 'https://discord.com/api/webhooks/%s/%s' 123456789012345678 "$(printf 'm%.0s' $(seq 1 40))")"
shape "an age secret key" "$(printf '%s%s' 'AGE-SECRET-KEY-1' "$(printf 'Q%.0s' $(seq 1 58))")"
shape "a base64 tunnel token without dots" "$(printf '%s%s' eyJ "$(printf 'a%.0s' $(seq 1 120))")"
shape "a dp-style API key" "$(printf 'dp.%s.%s' st abcdefghijklmnop)"
shape "a home directory on macOS" "$(printf '/%s/%s' Users alice)/work"
shape "a password in a connection string" "$(printf '%s%s%s:%s@%s/db' postgres '://' user pass db.internal)"
echo "-- red-team round four: scan.sh"
m="$(mk)"; printf 'host: %s\n' "$(printf '%s%s' acmeqq xzzhost)" > "$m/note.md"; printf '   \t%s\n' "$(printf '%s%s' acmeqq xzzhost)" > "$ld/leadws.pats"
( cd "$m" && KIT_DENYLIST_LOCAL="$ld/leadws.pats" ./scan.sh >"$m/.scanout" 2>&1 ); [ $? = 1 ] && ok "a local pattern with leading spaces or tabs still matches: the whitespace is trimmed, not searched for" || bad "leading whitespace in a local pattern"
akey="$(printf '%s%s' AKIAIOSFODNN 7EXAMPLE)"; mail="$(printf '%s%s%s' who '@' 'corp.example')"
m="$(mk)"; mkdir -p "$m/sub" "$m/denylist.generic.txt:"; printf '%s\n%s\n' "$akey" "$mail" > "$m/sub/denylist.generic.txt"; cp "$m/sub/denylist.generic.txt" "$m/denylist.generic.txt:/denylist.generic.txt"; git -C "$m" add -A; sgit "$m" commit -q -m nested
{ [ "$(scanrc "$m")" = 1 ] && grep -q 'HIT generic' "$m/.scanout"; } && ok "a file named like the shipped list, nested or in a colon-named directory, is scanned like any other (tree)" || bad "nested generic list name (tree)"
{ [ "$(scanrc "$m" --history)" = 1 ] && grep -q 'HIT generic' "$m/.scanout"; } && ok "and in history" || bad "nested generic list name (history)"
m="$(mk)"; mkdir -p "$m/sub"; printf 'host: %s\n' "$idf" > "$m/sub/denylist.localnotes.md"; git -C "$m" add -A; sgit "$m" commit -q -m nestedlocal
{ [ "$(scanrc "$m")" = 1 ] && grep -q 'HIT local #1' "$m/.scanout"; } && ok "a nested file whose name starts with denylist.local is scanned too: only a root-level local list is skipped" || bad "nested local list name"
m="$(mk)"; mkdir -p "$m/sub"; printf 'x\n' > "$m/sub/denylist.local.txt"; git -C "$m" add -f sub/denylist.local.txt
{ [ "$(scanrc "$m")" = 1 ] && grep -q 'tracked' "$m/.scanout"; } && ok "a tracked local denylist is refused at any depth" || bad "nested tracked local list"
inv_ok=1
for cp in 034F 3164 1160 180B 206A FFA0 E0020 FFF9 0085 0008 001B 007F; do
  m="$(mk)"; python3 -c 'import sys; sys.stdout.buffer.write(("see zebra" + chr(int(sys.argv[1], 16)) + "quux here\n").encode())' "$cp" > "$m/note.txt"
  { [ "$(scanrc "$m")" = 1 ] && grep -q 'invisible' "$m/.scanout"; } || { inv_ok=0; echo "  not refused: U+$cp"; }
done
[ $inv_ok -eq 1 ] && ok "invisible, filler, tag, format and control characters are refused by Unicode property, not from a remembered list" || bad "invisible character set"
m="$(mk)"; python3 -c 'import sys; sys.stdout.buffer.write(("zebra" + chr(0xFE0F) + "quux\n").encode())' > "$m/note.txt"
[ "$(scanrc "$m")" = 1 ] && ok "a variation selector after a letter is refused: it can split an identifier" || bad "variation selector after a letter"
m="$(mk)"; python3 -c 'import sys; sys.stdout.buffer.write(("ok " + chr(0x23ED) + chr(0xFE0F) + " skipped\n\tindented\r\n").encode())' > "$m/note.txt"
[ "$(scanrc "$m")" = 0 ] && ok "but an emoji with its variation selector, tabs and CRLF line endings are fine" || bad "emoji false positive"
m="$(mk)"; printf 'x\n' > "$m/bad$(printf '\xff')name.md"; git -C "$m" add -A; sgit "$m" commit -q -m badname
{ [ "$(scanrc "$m")" = 1 ] && grep -q 'not valid UTF-8' "$m/.scanout"; } && ok "a file name that is not valid UTF-8 is refused" || bad "non-UTF-8 file name"
printf 'zebraquux$\n' > "$ld/anchored.pats"; m="$(mk)"
( cd "$m" && KIT_DENYLIST_LOCAL="$ld/anchored.pats" ./scan.sh >"$m/.scanout" 2>&1 ); r1=$?
{ [ $r1 = 2 ] && grep -q 'carriage return' "$m/.scanout"; } && ok "a pattern that ends in a bare \$ is refused: it cannot match a line that ends in a carriage return" || bad "anchored pattern ($r1)"
printf 'zebraquux[[:cntrl:]]*$\n' > "$ld/anchored2.pats"; printf 'host zebraquux\r\nnext\r\n' > "$m/crlf.md"
( cd "$m" && KIT_DENYLIST_LOCAL="$ld/anchored2.pats" ./scan.sh >"$m/.scanout" 2>&1 ); r1=$?
printf 'zebraquux[$]\n' > "$ld/anchored3.pats"; ( cd "$m" && KIT_DENYLIST_LOCAL="$ld/anchored3.pats" ./scan.sh >"$m/.scanout3" 2>&1 ); r3=$?
{ [ $r1 = 1 ] && [ $r3 != 2 ]; } && ok "the CR-safe spelling works on a CRLF file, and a literal dollar inside brackets is not an anchor" || bad "CR-safe anchored pattern ($r1 $r3)"
for badc in '\n' '\t' '\r'; do
  m="$(mk)"; ( cd "$m" && python3 -c 'import os, sys; d = "x" + sys.argv[1].encode().decode("unicode_escape") + "./denylist.generic.txt"; os.makedirs(d); open(os.path.join(d, "note.txt"), "w").write("x\n")' "$badc" ); git -C "$m" add -A >/dev/null 2>&1; sgit "$m" commit -q -m names
  r1="$(scanrc "$m")"; r2="$(scanrc "$m" --history)"; g1="$(grep -c 'newline, carriage return or tab' "$m/.scanout")"
  { [ "$r1" = 1 ] && [ "$r2" = 1 ] && [ "$g1" -ge 1 ]; } && ok "a name holding $(printf '%s' "$badc" | tr -d '\\' | sed 's/n/a newline/; s/t/a tab/; s/r/a carriage return/') is refused in the tree scan and in history" || bad "control character in a name ($badc: tree $r1, history $r2)"
done
lint_ok=1; m="$(mk)"
for p in 'qzxv$' 'qzxv$|abcd' '(qzxv$)' 'qzxv\$$' '[a]$'; do
  printf '%s\n' "$p" > "$ld/lint.pats"; ( cd "$m" && KIT_DENYLIST_LOCAL="$ld/lint.pats" ./scan.sh >"$m/.scanout" 2>&1 ); [ $? = 2 ] || { lint_ok=0; echo "  anchored pattern accepted: $p"; }
done
for p in 'qzxv[$]' 'qzxv\$' 'qzxv[[:cntrl:]]*$' 'qzxv[^]$]' 'qzxv[]$]' 'qzxv[[:space:]$]' 'qzxv[^$]' 'qzxv[[:alpha:]$]'; do
  printf '%s\n' "$p" > "$ld/lint.pats"; ( cd "$m" && KIT_DENYLIST_LOCAL="$ld/lint.pats" ./scan.sh >"$m/.scanout" 2>&1 ); [ $? = 0 ] || { lint_ok=0; echo "  valid pattern refused: $p"; }
done
[ $lint_ok -eq 1 ] && ok "the dollar lint refuses a bare anchor however it is nested, and accepts a dollar that is escaped, inside a bracket expression, or behind the carriage-return class" || bad "dollar lint table"
m="$(mk)"; shimd="$(mktemp -d)"; printf '#!/bin/bash\nif [ "$1" = cat-file ] && [ "$2" = --batch ]; then %s cat-file --batch | head -c -11; exit 128; fi\nexec %s "$@"\n' "$(command -v git)" "$(command -v git)" > "$shimd/git"; chmod +x "$shimd/git"
sgit "$m" commit -q --allow-empty -m "tail $idf"
( cd "$m" && PATH="$shimd:$PATH" ./scan.sh --history >"$m/.scanout" 2>&1 ); [ $? -eq 2 ] && ok "a git that dies mid-stream while the history is read cannot read as clean" || bad "truncated cat-file"
( cd "$m" && TMPDIR=/nonexistent ./scan.sh >"$m/.scanout" 2>&1 ); r1=$?; { [ $r1 = 2 ] && grep -q 'cannot create a temporary directory' "$m/.scanout"; } && ok "no temporary directory means no attestation, and it says why" || bad "mktemp failure ($r1)"
sc="$(mk)"; sh9="$(mktemp -d)"; mkdir -p "$sh9/g"; printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = -qax ] && exit 0; done\nexec %s "$@"\n' "$(command -v grep)" > "$sh9/g/grep"; chmod +x "$sh9/g/grep"
( cd "$sc" && PATH="$sh9/g:$PATH" ./scan.sh >"$sc/.scanout" 2>&1 ); r1=$?; { [ $r1 = 2 ] && grep -q 'no UTF-8 locale' "$sc/.scanout"; } && ok "a system with no real UTF-8 locale cannot attest, however the probe is fooled" || bad "utf8 probe ($r1)"
lp="$(mktemp -d)"; for tool in bash git grep sed env cat xargs tr cut head tail sort wc dirname basename mkdir rm mktemp uname awk find ls split python3 uniq; do ln -s "$(command -v $tool)" "$lp/$tool" 2>/dev/null; done
( cd "$sc" && PATH="$lp" ./scan.sh >"$sc/.scanout" 2>&1 ); r1=$?; ( cd "$sc" && PATH="$lp" ./scan.sh --history >"$sc/.scanout2" 2>&1 ); r2=$?
{ [ $r1 = 0 ] && [ $r2 = 0 ]; } && ok "it runs without a coreutils timeout on the PATH" || bad "no timeout binary ($r1 $r2)"
( cd "$sc" && ./scan.sh --bogus >"$sc/.scanout" 2>&1 ); r1=$?; grep -q '^usage: scan.sh' "$sc/.scanout" || r1=99
rm -f "$sc/denylist.generic.txt"; ( cd "$sc" && ./scan.sh >"$sc/.scanout" 2>&1 ); r2=$?; grep -q 'denylist.generic.txt is missing' "$sc/.scanout" || r2=99
[ "$r1$r2" = 22 ] && ok "an unknown argument is a usage error, and a missing shipped list cannot attest (exit 2)" || bad "scan usage and missing list ($r1 $r2)"
np="$(mktemp -d)"; cp scan.sh denylist.generic.txt "$np/"; ( cd "$np" && ./scan.sh --history >"$np/.scanout" 2>&1 ); r1=$?
{ [ $r1 = 2 ] && grep -q 'needs a git repository' "$np/.scanout"; } && ok "--history outside a git repository cannot attest" || bad "history without a repository ($r1)"
( cd "$np" && ./scan.sh >"$np/.scanout" 2>&1 ); [ $? -eq 0 ] && ok "and the tree scan still works there" || bad "tree scan outside a repository"
er="$(mktemp -d)"; git init -q -b main "$er"; cp scan.sh denylist.generic.txt "$er/"; ( cd "$er" && ./scan.sh --history >"$er/.scanout" 2>&1 ); r1=$?
{ [ $r1 = 2 ] && grep -q 'no commits' "$er/.scanout"; } && ok "a repository with no commits has nothing to attest (exit 2)" || bad "no commits ($r1)"
m="$(mk)"; printf 'host: %s\n' "$idf" > "$m/ordinary-name.txt"; git -C "$m" add -A; sgit "$m" commit -q -m notes
scanrc "$m" >/dev/null; grep -q './ordinary-name.txt:1' "$m/.scanout" && ok "an ordinary hit prints its path and line (only paths that hold an identifier are withheld)" || bad "ordinary path not shown (tree)"
scanrc "$m" --history >/dev/null; grep -qE '^    [0-9a-f]{8}:ordinary-name.txt:1' "$m/.scanout" && ok "and in history it prints the short commit, the path and the line" || bad "ordinary path not shown (history)"
m="$(mk)"; for n in 1 2 3 4 5 6 7 8; do printf 'host: %s %s\n' "$idf" "$n"; done > "$m/many.txt"; scanrc "$m" >/dev/null
grep -q '\.\.\. (8 locations)' "$m/.scanout" && [ "$(grep -c '^    ./many.txt' "$m/.scanout")" = 5 ] && ok "more than five locations print five and a count" || bad "location count"
m="$(mk)"; for n in 1 2 3 4 5; do printf 'host: %s %s\n' "$idf" "$n"; done > "$m/five.txt"; scanrc "$m" >/dev/null
{ [ "$(grep -c '^    ./five.txt' "$m/.scanout")" = 5 ] && ! grep -q 'locations)' "$m/.scanout"; } && ok "exactly five locations print no count line" || bad "five locations"
m="$(mk)"; printf 'x\n' > "$m/$idf.txt"; scanrc "$m" >/dev/null; grep -q 'HIT local #1 in a file name' "$m/.scanout" && ok "a hit in a file name says so, without repeating the name" || bad "file name hit message"
m="$(mk)"; ctree="$(git -C "$m" rev-parse 'HEAD^{tree}')"; cpar="$(git -C "$m" rev-parse HEAD)"; armor="$(printf '%s%s' abcdefghijkmnopqrstuvwxyz ABCDEFGHJKLMN)"
hc="$(printf 'tree %s\nparent %s\nauthor t <%s> 1700000000 +0000\ncommitter t <%s> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n %s\n -----END PGP SIGNATURE-----\n\nmsg\n' "$ctree" "$cpar" "$nr" "$nr" "$armor" | git -C "$m" hash-object -t commit -w --stdin --literally)"; git -C "$m" update-ref refs/heads/sig "$hc"
scanrc "$m" --history >/dev/null; { grep -q 'signed commits' "$m/.scanout" && ! grep -q 'HIT generic' "$m/.scanout"; } && ok "the armour of a signature is refused as a signature, not scanned as text (no false base58 hit)" || bad "signature armour fed to the patterns"
m="$(mk)"; ctree="$(git -C "$m" rev-parse 'HEAD^{tree}')"; cpar="$(git -C "$m" rev-parse HEAD)"
hc="$(printf 'tree %s\nparent %s\nparent %s\nauthor t <%s> 1700000000 +0000\ncommitter t <%s> 1700000000 +0000\nmergetag object %s\n type commit\n tag signed\n \n %s\n\nmsg\n' "$ctree" "$cpar" "$cpar" "$nr" "$nr" "$cpar" "$armor" | git -C "$m" hash-object -t commit -w --stdin --literally)"; git -C "$m" update-ref refs/heads/merge "$hc"
scanrc "$m" --history >/dev/null; { grep -q 'merge of a signed tag' "$m/.scanout" && ! grep -q 'HIT generic' "$m/.scanout"; } && ok "a merge of a signed tag is refused, and its embedded tag text is not scanned as a message" || bad "mergetag"
m="$(mk)"; csha="$(git -C "$m" rev-parse HEAD)"
tg="$(printf 'object %s\ntype commit\ntag %s\ntagger t <%s> 1700000000 +0000\n\nclean message\n' "$csha" "$idf" "$nr" | git -C "$m" hash-object -t tag -w --stdin --literally)"; git -C "$m" update-ref refs/tags/clean-name "$tg"
scanrc "$m" --history >/dev/null; grep -q 'HIT local #1 in history metadata' "$m/.scanout" && ok "an identifier in a tag object's own name header is read even when the ref name is clean" || bad "tag header"

echo "== docs consistency"
n_les="$(grep -cE '^[0-9]+\. \*\*' LESSONS.md)"
w="$(sed -n '1s/^# \([A-Za-z]*\) lessons.*/\1/p' LESSONS.md | tr 'A-Z' 'a-z')"
declared=0; for kv in twelve=12 thirteen=13 fourteen=14 fifteen=15 sixteen=16 seventeen=17 eighteen=18 nineteen=19 twenty=20; do [ "${kv%%=*}" = "$w" ] && declared="${kv##*=}"; done
[ "$n_les" = "$declared" ] && ok "LESSONS heading ($w) matches its $n_les items" || bad "LESSONS heading says '$w' ($declared); the file has $n_les items"
grep -qi "$w operating lessons" README.md && ok "README quotes the same count" || bad "README count differs from the LESSONS heading"
missing=0; for p in $(grep -oE '`[^` ]+`' README.md | tr -d '`' | grep -E '^(kit/|[A-Za-z_.-]+\.(md|sh|txt))'); do [ -e "$p" ] || { echo "  missing: $p"; missing=1; }; done
[ $missing -eq 0 ] && ok "every path the README names exists" || bad "the README names a path that does not exist"
ph="$(printf '%s-%s' PENDING RESULT)"
if git grep -n -E "$ph|<operator:" -- . ':(exclude)test.sh' >"$kit_tmp/ph.out" 2>/dev/null; then cat "$kit_tmp/ph.out"; bad "a placeholder that must not ship is still in the tree"; else ok "no unfinished placeholder (a pending result, an <operator:> note) is left in the tree"; fi

echo "== ff-only"
kit/timers/ff-only.sh --self-test >/dev/null && ok "self-test" || bad "self-test"
ff="$(mktemp -d)"; git init -q -b main "$ff/up"; git -C "$ff/up" config user.email t@t; git -C "$ff/up" config user.name t; echo a > "$ff/up/f"; git -C "$ff/up" add f; git -C "$ff/up" commit -q -m a
git clone -q "$ff/up" "$ff/sh"; git -C "$ff/sh" config user.email t@t; git -C "$ff/sh" config user.name t
ffrun() { env KIT_FF_TREE="$ff/sh" KIT_FF_LOG="$ff/log" "$@" bash "$kr/kit/timers/ff-only.sh" >"$ff/out" 2>&1; echo $?; }   # ffrun [VAR=value] [--flag]: prints the exit code
tip() { git -C "$ff/up" rev-parse HEAD; }
a0="$(tip)"
[ "$(ffrun)" = 0 ] && grep -q "NOOP already=$a0" "$ff/log" && ok "ff-only: a checkout already at origin/main logs NOOP and exits 0" || bad "ff-only NOOP"
git -C "$ff/up" commit -q --allow-empty -m b; b0="$(tip)"
env KIT_FF_TREE="$ff/sh" KIT_FF_LOG="$ff/log" bash "$kr/kit/timers/ff-only.sh" --dry-run >"$ff/out" 2>&1; r1=$?
{ [ $r1 = 0 ] && grep -q "WOULD_FF $a0 -> $b0" "$ff/log" && [ "$(git -C "$ff/sh" rev-parse HEAD)" = "$a0" ]; } && ok "ff-only --dry-run says what it would do and moves nothing" || bad "ff-only dry run ($r1)"
[ "$(ffrun)" = 0 ] && [ "$(tail -1 "$ff/log" | cut -d' ' -f2-)" = "FF $a0 -> $b0" ] && [ "$(git -C "$ff/sh" rev-parse HEAD)" = "$b0" ] && ok "ff-only fast-forwards, logs it as the last line, and exits 0" || bad "ff-only fast-forward"
git -C "$ff/up" commit -q --allow-empty -m c; c0="$(tip)"; echo changed > "$ff/sh/f"
[ "$(ffrun)" = 0 ] && grep -q 'REFUSE.*tracked_dirty' "$ff/log" && [ "$(git -C "$ff/sh" rev-parse HEAD)" = "$b0" ] && ok "ff-only refuses on a changed tracked file, exits 0, and moves nothing" || bad "ff-only tracked dirt"
git -C "$ff/sh" checkout -q -- f; : > "$ff/sh/untracked.txt"
[ "$(ffrun)" = 0 ] && [ "$(git -C "$ff/sh" rev-parse HEAD)" = "$c0" ] && ok "an untracked file does not block the fast-forward" || bad "ff-only untracked file"
rm -f "$ff/sh/untracked.txt"; echo new > "$ff/up/clash.txt"; git -C "$ff/up" add clash.txt; git -C "$ff/up" commit -q -m clash; d0="$(tip)"; echo mine > "$ff/sh/clash.txt"
[ "$(ffrun)" = 1 ] && grep -q 'FAIL.*ff-only rejected' "$ff/log" && ok "an untracked file the merge would overwrite makes it FAIL (exit 1), with git's reason" || bad "ff-only clash"
rm -f "$ff/sh/clash.txt"; [ "$(ffrun)" = 0 ] && [ "$(git -C "$ff/sh" rev-parse HEAD)" = "$d0" ] || bad "ff-only after the clash"
git -C "$ff/sh" checkout -q -b side
[ "$(ffrun)" = 0 ] && grep -q 'REFUSE.*branch=side' "$ff/log" && ok "ff-only refuses on the wrong branch" || bad "ff-only wrong branch"
git -C "$ff/sh" checkout -q main; git -C "$ff/sh" commit -q --allow-empty -m local
[ "$(ffrun)" = 0 ] && grep -q 'REFUSE.*ahead' "$ff/log" && ok "ff-only refuses when the checkout is ahead of origin" || bad "ff-only ahead"
git -C "$ff/up" commit -q --allow-empty -m newer
[ "$(ffrun)" = 0 ] && grep -q 'REFUSE.*diverged' "$ff/log" && ok "and when it has diverged" || bad "ff-only diverged"
git -C "$ff/sh" reset -q --hard "$d0"; : > "$(git -C "$ff/sh" rev-parse --absolute-git-dir)/index.lock"
[ "$(ffrun)" = 0 ] && grep -q 'REFUSE.*index.lock' "$ff/log" && ok "and while an index.lock exists" || bad "ff-only index.lock"
rm -f "$(git -C "$ff/sh" rev-parse --absolute-git-dir)/index.lock"
[ "$(ffrun KIT_FF_REMOTE=no-such-remote)" = 1 ] && grep -q 'FAIL.*fetch rejected' "$ff/log" && ok "a failed fetch is a FAIL (exit 1) that logs its reason" || bad "ff-only fetch failure"
[ "$(ffrun KIT_FF_TREE=/nonexistent/tree)" = 1 ] && grep -q 'FAIL.*not a git checkout' "$ff/log" && ok "a path that is not a git checkout is a FAIL (exit 1)" || bad "ff-only not a checkout"
env KIT_FF_TREE="$ff/sh" KIT_FF_LOG="$ff/log" bash "$kr/kit/timers/ff-only.sh" --bogus >"$ff/out" 2>&1; [ $? -eq 2 ] && grep -q usage "$ff/out" && ok "an unknown flag is a usage error (exit 2)" || bad "ff-only usage"

# the timer must not run hooks: a relative core.hooksPath would run the incoming tree's hooks unattended
hk="$(mktemp -d)"; git init -q -b main "$hk/up"; git -C "$hk/up" config user.email t@t; git -C "$hk/up" config user.name t; echo a > "$hk/up/f"; git -C "$hk/up" add f; git -C "$hk/up" commit -q -m a
for who in timer control; do git clone -q "$hk/up" "$hk/$who"; git -C "$hk/$who" config user.email t@t; git -C "$hk/$who" config user.name t; git -C "$hk/$who" config core.hooksPath kit/hooks; done
mkdir -p "$hk/up/kit/hooks"; printf '#!/bin/sh\ntouch "$HOOK_MARK"\n' > "$hk/up/kit/hooks/post-merge"; chmod +x "$hk/up/kit/hooks/post-merge"; git -C "$hk/up" add -A; git -C "$hk/up" commit -q -m "a hook arrives"
( cd "$hk/control" && git fetch -q origin main && HOOK_MARK="$hk/control.mark" git merge -q --ff-only origin/main >/dev/null 2>&1 )
env KIT_FF_TREE="$hk/timer" KIT_FF_LOG="$hk/log" HOOK_MARK="$hk/timer.mark" bash "$kr/kit/timers/ff-only.sh" >/dev/null 2>&1
{ [ -e "$hk/control.mark" ] && [ ! -e "$hk/timer.mark" ] && [ "$(git -C "$hk/timer" rev-parse HEAD)" = "$(git -C "$hk/up" rev-parse HEAD)" ]; } && ok "ff-only runs no hooks: a plain merge of the same commit runs the incoming post-merge hook, the timer's does not, and it still fast-forwards" || bad "ff-only ran a hook (control $( [ -e "$hk/control.mark" ] && echo ran || echo did-not-run ), timer $( [ -e "$hk/timer.mark" ] && echo ran || echo did-not-run ))"
echo "== gate-record verdicts"
v() { kit/ops/gate-record.sh "$sha" "$1" "$2" >/dev/null 2>&1; echo $?; }
[ "$(v filtered 'RESULT: 3 passed, 0 failed, 1 skipped')" = 0 ] && ok "pass" || bad "pass"
[ "$(v filtered 'RESULT: 0 passed, 0 failed, 14 skipped')" = 1 ] && ok "no-op is fail" || bad "no-op is fail"
[ "$(v filtered 'RESULT: 2 passed, 1 failed, 0 skipped')" = 1 ] && ok "failed job is fail" || bad "failed job is fail"
[ "$(v filtered 'garbage')" = 1 ] && ok "no RESULT line is fail" || bad "no RESULT line is fail"
[ "$(v none '')" = 1 ] && ok "scope none is fail" || bad "scope none is fail"
[ "$(KIT_GATE_STATE_DIR=/proc/nope/x v filtered 'RESULT: 0 passed, 5 failed, 0 skipped')" = 1 ] && ok "an unwritable state dir cannot turn a failing verdict into success" || bad "unwritable state dir with a failing verdict"
[ "$(KIT_GATE_STATE_DIR=/proc/nope/x v filtered 'garbage')" = 1 ] && ok "and garbage is still a failure" || bad "unwritable state dir with garbage"
[ "$(KIT_GATE_STATE_DIR=/proc/nope/x v filtered 'RESULT: 3 passed, 0 failed, 0 skipped')" = 0 ] && ok "and a real pass still passes" || bad "unwritable state dir with a pass"
[ "$(v all 'RESULT: 3 passed, 0 failed, 1 skipped')" = 2 ] && ok "caller-asserted all refused" || bad "caller-asserted all refused"
KIT_GATE_RAN_ALL=1 kit/ops/gate-record.sh "$sha" all 'RESULT: 1 passed, 0 failed, 45 skipped' >/dev/null 2>&1; [ $? -eq 1 ] && ok "all with more skips than passes is fail" || bad "all with more skips than passes is fail"
[ "$(v filtered 'RESULT: 5 passed')" = 1 ] && ok "a RESULT line missing the failed count is fail, not a pass" || bad "partial RESULT line"
grx="$(mktemp -d)"; KIT_GATE_STATE_DIR="$grx" kit/ops/gate-record.sh "$sha" filtered '' >/dev/null 2>&1; r1=$?
{ [ $r1 = 1 ] && grep -q '"verdict":"fail"' "$grx/$sha.json" && grep -q 'no parseable RESULT line' "$grx/$sha.json"; } && ok "an empty RESULT line is fail and the record says why" || bad "empty result line ($r1)"
kit/ops/gate-record.sh >/dev/null 2>&1; r1=$?; kit/ops/gate-record.sh "$sha" >/dev/null 2>&1; r2=$?; kit/ops/gate-record.sh "" filtered 'RESULT: 3 passed, 0 failed, 0 skipped' >/dev/null 2>&1; r3=$?
[ "$r1$r2$r3" = 222 ] && ok "a missing sha or scope is a usage error (exit 2)" || bad "gate-record usage ($r1$r2$r3)"
kit/ops/gate-record.sh "$sha" bogus 'RESULT: 3 passed, 0 failed, 0 skipped' >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown scope is refused (exit 2)" || bad "unknown scope"
grd="$(mktemp -d)"; KIT_GATE_STATE_DIR="$grd" kit/ops/gate-record.sh "$sha" filtered 'RESULT: 3 passed, 0 failed, 1 skipped' >/dev/null 2>&1
{ grep -q "\"tree\":\"$(git rev-parse 'HEAD^{tree}' | cut -c1-12)\"" "$grd/$sha.json" && grep -q '"verdict":"pass"' "$grd/$sha.json" && grep -q '"scope":"filtered"' "$grd/$sha.json" && grep -q '"passed":"3"' "$grd/$sha.json" && grep -q '"skipped":"1"' "$grd/$sha.json"; } && ok "the record names the tree, the verdict, the scope and the counts it vouches for" || bad "record contents"

echo "== pre-push with fake gates"
t="$(mktemp -d)"; git init -q -b main "$t"; mkdir -p "$t/ops" "$t/kit/hooks"; cp kit/hooks/pre-push "$t/kit/hooks/"; cp kit/ops/gate-record.sh "$t/ops/"
printf 'ops/local-ci.sh\n' > "$t/.gitignore"   # the gate is rewritten by the tests below; everything else is committed
git -C "$t" add -A; ( cd "$t" && git -c user.name=t -c user.email=t@t commit -q -m x )
s="$(git -C "$t" rev-parse HEAD)"; line="x $s y 0000000000000000000000000000000000000000"
printf '#!/bin/bash\necho "RESULT: 0 passed, 0 failed, 9 skipped"; exit 0\n' > "$t/ops/local-ci.sh"; chmod +x "$t/ops/local-ci.sh"
( cd "$t" && echo "$line" | bash kit/hooks/pre-push >"$t/../pp-noop.txt" 2>&1 ); r1=$?; { [ $r1 -eq 1 ] && grep -q 'ran no checks' "$t/../pp-noop.txt" && grep -q 'KIT_SKIP_LOCAL_CI\|emergency override' "$t/../pp-noop.txt"; } && ok "no-op gate refuses push, and says a gate that ran nothing is the cause" || bad "no-op gate refuses push ($r1)"
rm -f "$t/../pp-noop.txt"
printf '#!/bin/bash\necho "RESULT: 5 passed, 0 failed, 2 skipped"; exit 0\n' > "$t/ops/local-ci.sh"
( cd "$t" && echo "$line" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "passing gate allows push" || bad "passing gate allows push"
grep -q '"verdict":"pass","scope":"filtered"' "$KIT_GATE_STATE_DIR/$s.json" 2>/dev/null && ok "verdict recorded against pushed sha" || bad "verdict recorded against pushed sha"
( cd "$t" && echo "$line" | KIT_SKIP_LOCAL_CI=1 bash kit/hooks/pre-push >/dev/null 2>&1 ); grep -q '"verdict":"fail","scope":"none"' "$KIT_GATE_STATE_DIR/$s.json" && ok "override recorded as not gated" || bad "override recorded as not gated"
( cd "$t" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m y ); s2="$(git -C "$t" rev-parse HEAD)"
( cd "$t" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m z )
( cd "$t" && echo "x $s2 y 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "pushing a commit that is not the checked-out HEAD is refused" || bad "pushed sha is not HEAD"
grep -q '"verdict":"fail","scope":"none"' "$KIT_GATE_STATE_DIR/$s2.json" 2>/dev/null && ok "the commit nobody gated is recorded as not gated" || bad "unvouched commit recorded"
echo a > "$t/tracked.txt"; git -C "$t" add tracked.txt; ( cd "$t" && git -c user.name=t -c user.email=t@t commit -q -m w ); s3="$(git -C "$t" rev-parse HEAD)"; echo b >> "$t/tracked.txt"
( cd "$t" && echo "x $s3 y 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "a dirty tracked file refuses the push (the gate would test uncommitted code)" || bad "dirty tree refuses the push"
git -C "$t" checkout -q -- tracked.txt
pp() { printf '#!/bin/bash\n%s\n' "$1" > "$t/ops/local-ci.sh"; ( cd "$t" && echo "x $s3 y 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push >/dev/null 2>&1 ); echo $?; }
[ "$(pp 'echo "RESULT: 3 passed, 1 failed, 0 skipped"')" = 1 ] && ok "a failed job refuses the push" || bad "failed job refuses the push"
[ "$(pp 'echo "RESULT: 5 passed, 0 failed, 0 skipped"; exit 3')" = 1 ] && ok "a non-zero gate exit refuses the push even with a clean RESULT line" || bad "non-zero gate exit"
[ "$(pp 'echo "all done"')" = 1 ] && ok "no RESULT line refuses the push" || bad "no RESULT line"
[ "$(pp 'echo "RESULT: 5 passed, 0 failed, 0 skipped"')" = 0 ] && ok "a clean RESULT line allows the push" || bad "clean RESULT line"
grep -q '"verdict":"pass","scope":"filtered"' "$KIT_GATE_STATE_DIR/$s3.json" && ok "and the verdict is recorded on the pushed commit" || bad "verdict recorded on the pushed commit"
rm -f "$t/ops/local-ci.sh"; ( cd "$t" && echo "x $s3 y 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 0 ] && grep -q '"verdict":"fail","scope":"none"' "$KIT_GATE_STATE_DIR/$s3.json" && ok "a missing gate is recorded as not gated" || bad "missing gate recorded as not gated"
printf '#!/bin/bash\necho "RESULT: 0 passed, 3 failed, 0 skipped"; exit 1\n' > "$t/ops/local-ci.sh"; chmod +x "$t/ops/local-ci.sh"; rm -f "$KIT_GATE_STATE_DIR/$s3.json"
( cd "$t" && echo "(delete) 0000000000000000000000000000000000000000 refs/heads/gone $s3" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 0 ] && [ ! -e "$KIT_GATE_STATE_DIR/$s3.json" ] && ok "a delete-only push is not gated and records nothing" || bad "delete-only push"
( cd "$t" && printf 'a %s b 0000000000000000000000000000000000000000\na %s c 0000000000000000000000000000000000000000\n' "$s2" "$s3" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "a push of two different commits is refused" || bad "multi-ref push"
echo untracked > "$t/untracked.txt"
[ "$(pp 'echo "RESULT: 5 passed, 0 failed, 0 skipped"')" = 1 ] && ok "an untracked file refuses the push (the gate may have used a file the commit lacks)" || bad "untracked file refuses the push"
git -C "$t" config status.showUntrackedFiles no
[ "$(pp 'echo "RESULT: 5 passed, 0 failed, 0 skipped"')" = 1 ] && ok "and the refusal holds when status.showUntrackedFiles=no tries to hide the file" || bad "showUntrackedFiles=no hid an untracked file"
git -C "$t" config --unset status.showUntrackedFiles
rm -f "$t/untracked.txt"
git -C "$t" -c user.name=t -c user.email=t@t tag -a v1 -m rel; tagobj="$(git -C "$t" rev-parse v1)"
printf '#!/bin/bash\necho "RESULT: 5 passed, 0 failed, 0 skipped"\n' > "$t/ops/local-ci.sh"
( cd "$t" && echo "refs/tags/v1 $tagobj refs/tags/v1 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "an annotated tag is gated as the commit it names" || bad "annotated tag push"
printf '#!/bin/bash\necho "RESULT: 0 passed, 3 failed, 0 skipped"; exit 1\n' > "$t/ops/local-ci.sh"   # from here the gate always fails, so any gating shows
git -C "$t" remote add origin "$t/nowhere.git"; git -C "$t" update-ref refs/remotes/origin/main "$s3"; rm -f "$KIT_GATE_STATE_DIR/$s3.json"
( cd "$t" && echo "refs/heads/feature/empty $s3 refs/heads/feature/empty 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push origin >"$t.out" 2>&1 ); [ $? -eq 0 ] && grep -q "already on origin" "$t.out" && [ ! -e "$KIT_GATE_STATE_DIR/$s3.json" ] && ok "a new branch or tag at a commit the remote already has is not gated and records nothing (no emergency override needed)" || bad "push of a commit already on the remote"
( cd "$t" && echo "refs/heads/feature/empty $s3 refs/heads/feature/empty 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push "file:///nonexistent" >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "but a URL, which names no remote-tracking branch, is gated as usual" || bad "push to a URL"
mkdir -p "$t.shim"; printf '#!/bin/bash\n[ "$1" = rev-list ] && exit 128\nexec %s "$@"\n' "$(command -v git)" > "$t.shim/git"; chmod +x "$t.shim/git"
( cd "$t" && echo "refs/heads/feature/empty $s3 refs/heads/feature/empty 0000000000000000000000000000000000000000" | PATH="$t.shim:$PATH" bash kit/hooks/pre-push origin >"$t.out" 2>&1 ); r1=$?
{ [ $r1 -eq 1 ] && ! grep -q "already on" "$t.out"; } && ok "when git cannot say whether the remote has the commit, the push is gated, not waved through" || bad "rev-list failure ($r1)"
blobsha="$(printf 'not code\n' | git -C "$t" hash-object -w --stdin)"
( cd "$t" && echo "refs/tags/blobby $blobsha refs/tags/blobby 0000000000000000000000000000000000000000" | bash kit/hooks/pre-push origin >"$t.out" 2>&1 ); r1=$?
{ [ $r1 -ne 0 ] && ! grep -q "already on" "$t.out"; } && ok "a tag that points at a blob is never mistaken for a commit the remote already has" || bad "blob tag ($r1)"
( cd "$t" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "new work" ); s4="$(git -C "$t" rev-parse HEAD)"
( cd "$t" && echo "refs/heads/main $s4 refs/heads/main $s3" | bash kit/hooks/pre-push origin >/dev/null 2>&1 ); [ $? -eq 1 ] && ok "and a commit the remote does not have is still gated" || bad "new commit gated"

t5="$(mktemp -d)"; git init -q -b main "$t5"; mkdir -p "$t5/ops" "$t5/kit/hooks"; cp kit/hooks/pre-push "$t5/kit/hooks/"; cp kit/ops/gate-record.sh "$t5/ops/"
printf 'ops/local-ci.sh\n' > "$t5/.gitignore"; git -C "$t5" add -A; git -C "$t5" -c user.name=t -c user.email=t@t commit -q -m one; c1="$(git -C "$t5" rev-parse HEAD)"
git -C "$t5" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two; c2="$(git -C "$t5" rev-parse HEAD)"; zero=0000000000000000000000000000000000000000
gate5() { printf '#!/bin/bash\n%s\n' "$1" > "$t5/ops/local-ci.sh"; chmod +x "$t5/ops/local-ci.sh"; }
hook5() {   # hook5 <stdin text> [remote]: prints the exit code; the output stays in $t5.out
  ( cd "$t5" && printf '%b' "$1" | bash kit/hooks/pre-push ${2:+"$2"} >"$t5.out" 2>&1 ); echo $?
}
push2="refs/heads/main $c2 refs/heads/main $zero\n"
gate5 'echo "JOB FAILED: lint"; echo "RESULT: 1 passed, 1 failed, 0 skipped"; exit 1'
[ "$(hook5 "$push2")" = 1 ] && grep -q 'JOB FAILED: lint' "$t5.out" && grep -q 'gate did not pass (RESULT: 1 passed, 1 failed, 0 skipped)' "$t5.out" && ok "a failing gate refuses the push, shows the gate's own output, and quotes its RESULT line once" || bad "failing gate output"
gate5 'echo "RESULT: 5 passed, 0 failed, 0 skipped"'
rm -f "$KIT_GATE_STATE_DIR/$c2.json"
[ "$(hook5 "")" = 0 ] && grep -q '"verdict":"pass"' "$KIT_GATE_STATE_DIR/$c2.json" && ok "with nothing on stdin the hook gates and records HEAD" || bad "empty stdin"
[ "$(KIT_SKIP_LOCAL_CI=1 hook5 "$push2")" = 0 ] && grep -q 'recorded as NOT gated' "$t5.out" && grep -q '"verdict":"fail","scope":"none"' "$KIT_GATE_STATE_DIR/$c2.json" && ok "the emergency override pushes, says the commit is NOT gated, and records that" || bad "override"
rm -f "$t5/ops/local-ci.sh"
[ "$(hook5 "$push2")" = 0 ] && grep -q 'not found or not executable' "$t5.out" && ok "a missing gate lets the push through but says it was not gated" || bad "missing gate"
gate5 'echo "RESULT: 5 passed, 0 failed, 0 skipped"'
[ "$(hook5 "refs/heads/old $c1 refs/heads/old $zero\n")" = 1 ] && grep -q 'not the checked-out HEAD' "$t5.out" && ok "pushing a commit that is not the checked-out HEAD is refused with the reason" || bad "not HEAD message"
echo dirty >> "$t5/.gitignore"
[ "$(hook5 "$push2")" = 1 ] && grep -q 'working tree is not clean' "$t5.out" && ok "a dirty tree is refused with the reason" || bad "dirty tree message"
git -C "$t5" checkout -q -- .gitignore
[ "$(hook5 "refs/heads/a $c1 refs/heads/a $zero\nrefs/heads/b $c2 refs/heads/b $zero\n")" = 1 ] && grep -q 'carries 2 different commits' "$t5.out" && [ "$(grep -c '^pre-push:' "$t5.out")" = 1 ] && ok "a push of two different commits is refused with the reason, and for that reason alone" || bad "two commits message"
t6="$(mktemp -d)"; git init -q -b main "$t6"; mkdir -p "$t6/ops" "$t6/kit/hooks"; cp kit/hooks/pre-push "$t6/kit/hooks/"; git -C "$t6" remote add origin "$t6.nowhere"
printf '#!/bin/bash\necho "RESULT: 0 passed, 2 failed, 0 skipped"; exit 1\n' > "$t6/ops/local-ci.sh"; chmod +x "$t6/ops/local-ci.sh"
( cd "$t6" && bash kit/hooks/pre-push origin </dev/null >"$t6.out" 2>&1 ); [ $? -eq 1 ] && ok "with no commit at all the hook cannot call a push already on the remote, and the gate still runs" || bad "unborn HEAD"

echo "== local-ci skeleton"
out="$(KIT_GATE_BASE=HEAD~1 kit/ops/local-ci.sh --all 2>/dev/null)"; rc=$?
line="$(printf '%s\n' "$out" | grep -E '^RESULT:' | tail -1)"
[ $rc -eq 0 ] && ok "exits 0 with nothing failed" || bad "exits 0 with nothing failed"
[ -n "$line" ] && ok "prints a RESULT line ($line)" || bad "prints a RESULT line"
kit/ops/gate-record.sh "$sha" filtered "$line" >/dev/null 2>&1 && ok "recorder accepts it" || bad "recorder accepts it"
out="$(KIT_GATE_BASE=HEAD kit/ops/local-ci.sh 2>/dev/null)"; line="$(printf '%s\n' "$out" | grep -E '^RESULT:' | tail -1)"
kit/ops/gate-record.sh "$sha" filtered "$line" >/dev/null 2>&1; [ $? -eq 1 ] && ok "unchanged tree is skips only, recorder refuses it ($line)" || bad "unchanged tree refused"
out="$(KIT_GATE_BASE=HEAD kit/ops/local-ci.sh --all 2>/dev/null)"; line="$(printf '%s\n' "$out" | grep -E '^RESULT:' | tail -1)"
printf '%s' "$line" | grep -qE 'RESULT: [1-9][0-9]* passed' && ok "--all runs every job even when the diff against the base is empty ($line)" || bad "--all with an empty diff ($line)"
lc="$(mktemp -d)"; git init -q -b master "$lc"; mkdir -p "$lc/ops" "$lc/sub"; cp kit/ops/local-ci.sh "$lc/ops/"
printf 'def broken(:\n' > "$lc/broken.py"; git -C "$lc" add -A; git -C "$lc" -c user.name=t -c user.email=t@t commit -q -m one
printf 'notes\n' > "$lc/NOTES.md"; git -C "$lc" add -A; git -C "$lc" -c user.name=t -c user.email=t@t commit -q -m two
root_line="$(cd "$lc" && ops/local-ci.sh --all 2>/dev/null | grep '^RESULT:')"; sub_line="$(cd "$lc/sub" && ../ops/local-ci.sh --all 2>/dev/null | grep '^RESULT:')"
[ -n "$root_line" ] && [ "$root_line" = "$sub_line" ] && printf '%s' "$root_line" | grep -q ' 1 failed' && ok "run from a subdirectory the gate checks the whole repository, not just that subtree ($sub_line)" || bad "gate from a subdirectory ('$root_line' vs '$sub_line')"
filtered="$(cd "$lc" && ops/local-ci.sh 2>&1)"
printf '%s\n' "$filtered" | grep -q 'not usable here' && printf '%s\n' "$filtered" | grep -q 'FAIL python' && ok "with no origin/main the filtered gate says so and runs every job instead of checking less" || bad "unusable base"
( cd "$(mktemp -d)" && "$kr/kit/ops/local-ci.sh" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "outside a git repository the gate cannot run (exit 2)" || bad "gate outside a repository"
rm -rf "$lc"
lc2="$(mktemp -d)"; git init -q -b main "$lc2"; mkdir -p "$lc2/ops"; cp kit/ops/local-ci.sh "$lc2/ops/"
printf '#!/usr/bin/env bash\necho ok\n' > "$lc2/good.sh"; printf 'x = 1\n' > "$lc2/good.py"; printf '#!/bin/sh\nexit 0\n' > "$lc2/test.sh"; chmod +x "$lc2/test.sh"
git -C "$lc2" add -A; git -C "$lc2" -c user.name=t -c user.email=t@t commit -q -m base
gate2() { ( cd "$lc2" && env -u KIT_IN_SELFTEST ops/local-ci.sh --all 2>&1 ); }
out="$(gate2)"
miss=""; for job in shell-syntax shellcheck python conflict-markers kit-selftest; do printf '%s\n' "$out" | grep -qE "(PASS|SKIP|FAIL) $job" || miss="$miss $job"; done
[ -z "$miss" ] && printf '%s\n' "$out" | grep -q 'PASS shell-syntax' && printf '%s\n' "$out" | grep -q 'PASS python' && printf '%s\n' "$out" | grep -q 'PASS conflict-markers' && printf '%s\n' "$out" | grep -q 'PASS kit-selftest' && ok "the starter gate registers and runs all five jobs on a clean repository" || bad "starter gate jobs (missing:$miss)"
printf 'x=(\n' > "$lc2/bad.sh"; git -C "$lc2" add -A; git -C "$lc2" -c user.name=t -c user.email=t@t commit -q -m badsh
out="$(gate2)"; printf '%s\n' "$out" | grep -q 'FAIL shell-syntax' && printf '%s\n' "$out" | grep -qE 'RESULT: [0-9]+ passed, [1-9][0-9]* failed' && ok "a shell file with a syntax error fails the shell-syntax job and the RESULT line" || bad "shell syntax job"
git -C "$lc2" rm -q -f bad.sh; printf 'def f(:\n' > "$lc2/bad.py"; git -C "$lc2" add -A; git -C "$lc2" -c user.name=t -c user.email=t@t commit -q -m badpy
out="$(gate2)"; printf '%s\n' "$out" | grep -q 'FAIL python' && ok "a Python file that does not parse fails the python job" || bad "python job"
git -C "$lc2" rm -q -f bad.py; printf '%s\n' '<<<<<<< ours' > "$lc2/merge.txt"; git -C "$lc2" add -A; git -C "$lc2" -c user.name=t -c user.email=t@t commit -q -m marker
out="$(gate2)"; printf '%s\n' "$out" | grep -q 'FAIL conflict-markers' && ok "a committed conflict marker fails the conflict-markers job" || bad "conflict markers job"
git -C "$lc2" rm -q -f merge.txt; printf '#!/bin/sh\nexit 1\n' > "$lc2/test.sh"; git -C "$lc2" add -A; git -C "$lc2" -c user.name=t -c user.email=t@t commit -q -m failingtest
out="$(gate2)"; printf '%s\n' "$out" | grep -q 'FAIL kit-selftest' && ok "a failing ./test.sh fails the kit-selftest job" || bad "selftest job"
out="$( cd "$lc2" && KIT_IN_SELFTEST=1 ops/local-ci.sh --all 2>&1 )"; printf '%s\n' "$out" | grep -qE 'SKIP kit-selftest' && ok "and the self-test job skips itself when it is already running inside the self-test" || bad "selftest recursion guard"
lp="$(mktemp -d)"; for tool in bash git grep sed env cat xargs tr cut head tail sort wc dirname basename mkdir rm mktemp uname awk find ls; do ln -s "$(command -v $tool)" "$lp/$tool" 2>/dev/null; done
printf '#!/bin/sh\nexit 0\n' > "$lc2/test.sh"; git -C "$lc2" add -A; git -C "$lc2" -c user.name=t -c user.email=t@t commit -q -m ok
out="$( cd "$lc2" && PATH="$lp" ops/local-ci.sh --all 2>&1 )"; rc=$?
{ printf '%s\n' "$out" | grep -q 'SKIP shellcheck (tool absent)' && printf '%s\n' "$out" | grep -q 'SKIP python (tool absent)' && printf '%s\n' "$out" | grep -q 'PASS shell-syntax' && [ $rc = 0 ]; } && ok "a tool that is not installed is a SKIP, counted and said, never a pass or a failure" || bad "absent tools ($rc)"
rm -rf "$lc2"

ih="$(mktemp -d)"; git init -q -b main "$ih"; mkdir -p "$ih/kit/hooks"; cp kit/hooks/pre-commit kit/hooks/pre-push "$ih/kit/hooks/"
git -C "$ih" config core.hooksPath somewhere/else
( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); rc=$?
[ $rc -eq 1 ] && [ "$(git -C "$ih" config core.hooksPath)" = somewhere/else ] && ok "install-githooks will not replace an existing core.hooksPath" || bad "existing core.hooksPath (exit $rc)"
( cd "$ih" && KIT_FORCE_HOOKS=1 bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); [ "$(git -C "$ih" config core.hooksPath)" = kit/hooks ] && ok "and KIT_FORCE_HOOKS=1 overrides it deliberately" || bad "force override"
git -C "$ih" config --unset core.hooksPath; printf '#!/bin/sh\nexit 0\n' > "$ih/.git/hooks/pre-commit"; chmod +x "$ih/.git/hooks/pre-commit"
( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); rc=$?
[ $rc -eq 1 ] && [ -z "$(git -C "$ih" config core.hooksPath || true)" ] && ok "install-githooks will not orphan active hooks in .git/hooks" || bad "active .git/hooks (exit $rc)"
rm -rf "$ih"
lc="$(mktemp -d)"; git init -q -b main "$lc"; mkdir -p "$lc/ops"; cp kit/ops/local-ci.sh "$lc/ops/"; echo a > "$lc/README.md"
git -C "$lc" add -A; git -C "$lc" -c user.name=t -c user.email=t@t commit -q -m a; echo b >> "$lc/README.md"; git -C "$lc" -c user.name=t -c user.email=t@t commit -qam "docs only"
line="$(cd "$lc" && KIT_GATE_BASE=HEAD~1 ops/local-ci.sh 2>/dev/null | grep -E '^RESULT:')"
case "$line" in "RESULT: 1 passed, 0 failed,"*) ok "a docs-only change still runs a job, so the starter gate does not refuse it as a no-op ($line)" ;; *) bad "docs-only change ($line)" ;; esac
printf '<<<<<<< ours\n' > "$lc/README.md"; git -C "$lc" -c user.name=t -c user.email=t@t commit -qam "conflict marker"
( cd "$lc" && KIT_GATE_BASE=HEAD~1 ops/local-ci.sh >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "and a committed conflict marker fails it" || bad "conflict marker not caught"
rm -rf "$lc"
echo "== gate-attest --run end to end (fake gh)"
gr="$(mktemp -d)"; mkdir -p "$gr/bin" "$gr/r/ops" "$gr/r/sub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE_GH_LOG"\n' > "$gr/bin/gh"; chmod +x "$gr/bin/gh"
git init -q -b main "$gr/r"; cp kit/ops/gate-attest.sh kit/ops/gate-record.sh "$gr/r/ops/"; printf 'ops/local-ci.sh\n' > "$gr/r/.gitignore"; echo a > "$gr/r/sub/f"
git -C "$gr/r" add -A; git -C "$gr/r" -c user.name=t -c user.email=t@t commit -q -m a
gate() { printf '#!/bin/bash\ntouch "%s/ran"\necho "RESULT: 5 passed, 0 failed, 0 skipped"\nexit %s\n' "$gr" "$1" > "$gr/r/ops/local-ci.sh"; chmod +x "$gr/r/ops/local-ci.sh"; }
run_attest() {   # run_attest [VAR=val ...]: from a subdirectory, by a relative path, as an adopter would; prints the exit code
  rm -f "$gr/log" "$gr/ran"; rm -rf "$gr/state"
  ( cd "$gr/r/sub" && env PATH="$gr/bin:$PATH" FAKE_GH_LOG="$gr/log" KIT_GATE_STATE_DIR="$gr/state" "$@" bash ../ops/gate-attest.sh --run >"$gr/out" 2>&1 ); echo $?
}
gate 0
[ "$(run_attest KIT_GATE_REPO=o/r)" = 0 ] && grep -q 'state=success' "$gr/log" && grep -q 'running the FULL gate (--all)' "$gr/out" && ok "--run works from a subdirectory by a relative path, says it runs the FULL gate, and posts success" || bad "--run from a subdirectory"
gate 3
[ "$(run_attest KIT_GATE_REPO=o/r)" = 1 ] && grep -q 'state=failure' "$gr/log" && ok "a gate that exits non-zero is posted as failure even with a clean RESULT line" || bad "gate exit status ignored"
gate 0; echo x > "$gr/r/untracked.txt"
[ "$(run_attest KIT_GATE_REPO=o/r)" = 2 ] && [ ! -e "$gr/ran" ] && ok "--run refuses an untracked file and does not run the gate" || bad "untracked file with --run"
rm -f "$gr/r/untracked.txt"
[ "$(run_attest)" = 2 ] && [ ! -e "$gr/ran" ] && ok "--run checks KIT_GATE_REPO before it spends time on the gate" || bad "KIT_GATE_REPO checked late"
rm -rf "$gr"

echo "== gate-attest refuses to vouch for uncommitted code"
ga="$(mktemp -d)"; git init -q -b main "$ga"; mkdir -p "$ga/ops"; cp kit/ops/gate-attest.sh kit/ops/gate-record.sh "$ga/ops/"
printf '#!/bin/bash\necho "RESULT: 5 passed, 0 failed, 0 skipped"; exit 0\n' > "$ga/ops/local-ci.sh"; chmod +x "$ga/ops/"*.sh
echo a > "$ga/f"; git -C "$ga" add -A; ( cd "$ga" && git -c user.name=t -c user.email=t@t commit -q -m a ); echo b >> "$ga/f"
( cd "$ga" && KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga/state" ops/gate-attest.sh --run >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "gate-attest --run refuses a dirty tree" || bad "gate-attest --run on a dirty tree"
[ -z "$(ls -A "$ga/state" 2>/dev/null)" ] && ok "and records nothing" || bad "gate-attest recorded for a dirty tree"
git -C "$ga" checkout -q -- f; git -C "$ga" rm -q -f ops/local-ci.sh; git -C "$ga" -c user.name=t -c user.email=t@t commit -q -m "no gate"
out="$( cd "$ga" && KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga/state" ops/gate-attest.sh --run 2>&1 )"; rc=$?
{ [ $rc -eq 2 ] && printf '%s' "$out" | grep -q 'missing or not executable'; } && ok "gate-attest --run without a gate script cannot attest (exit 2)" || bad "gate-attest --run without a gate ($rc)"
git -C "$ga" checkout -q HEAD~1 -- ops/local-ci.sh; git -C "$ga" -c user.name=t -c user.email=t@t commit -q -m "gate back"
git -C "$ga" config status.showUntrackedFiles no; echo u > "$ga/untracked.txt"
( cd "$ga" && KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga/state" ops/gate-attest.sh --run >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "gate-attest --run refuses an untracked file even when status.showUntrackedFiles=no" || bad "gate-attest --run with hidden untracked files"
rm -rf "$ga"

echo "== install-githooks"
ih="$(mktemp -d)"; git init -q -b main "$ih"; mkdir -p "$ih/kit/hooks"
( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); rc=$?
[ $rc -eq 1 ] && [ -z "$(git -C "$ih" config core.hooksPath || true)" ] && ok "install-githooks refuses and changes nothing when the hooks are not there" || bad "install-githooks with no hooks (exit $rc)"
cp kit/hooks/pre-commit kit/hooks/pre-push "$ih/kit/hooks/"
chmod -x "$ih/kit/hooks/pre-commit" "$ih/kit/hooks/pre-push"
out="$( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" 2>&1 )"; rc=$?
{ [ $rc -eq 0 ] && [ "$(git -C "$ih" config core.hooksPath)" = kit/hooks ] && printf '%s' "$out" | grep -q 'hooks installed: kit/hooks'; } && ok "install-githooks points the clone at kit/hooks once they are there, and says so" || bad "install-githooks with hooks (exit $rc)"
{ [ -x "$ih/kit/hooks/pre-commit" ] && [ -x "$ih/kit/hooks/pre-push" ]; } && ok "and makes both hooks executable" || bad "hooks not made executable"
( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "running it again is fine" || bad "install-githooks twice"
git -C "$ih" config core.hooksPath other/hooks
out="$( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" 2>&1 )"; rc=$?
{ [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "already 'other/hooks'" && [ "$(git -C "$ih" config core.hooksPath)" = other/hooks ]; } && ok "an existing core.hooksPath is refused with exit 1 and left alone" || bad "existing hooksPath ($rc)"
( cd "$ih" && KIT_FORCE_HOOKS=1 bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); { [ $? -eq 0 ] && [ "$(git -C "$ih" config core.hooksPath)" = kit/hooks ]; } && ok "KIT_FORCE_HOOKS=1 replaces it, after you have looked" || bad "KIT_FORCE_HOOKS for hooksPath"
git -C "$ih" config --unset core.hooksPath; mkdir -p "$ih/.git/hooks"; printf '#!/bin/sh\n' > "$ih/.git/hooks/pre-commit"; chmod +x "$ih/.git/hooks/pre-commit"
out="$( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" 2>&1 )"; rc=$?
{ [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'already holds active hooks' && printf '%s' "$out" | grep -q 'pre-commit' && [ -z "$(git -C "$ih" config core.hooksPath || true)" ]; } && ok "active hooks in .git/hooks are named and refused with exit 1, and nothing is changed" || bad "active hooks ($rc)"
( cd "$ih" && KIT_FORCE_HOOKS=1 bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "KIT_FORCE_HOOKS=1 overrides that too" || bad "KIT_FORCE_HOOKS for active hooks"
git -C "$ih" config --unset core.hooksPath; rm -f "$ih/.git/hooks/pre-commit"; printf '#!/bin/sh\n' > "$ih/.git/hooks/pre-commit.sample"; chmod +x "$ih/.git/hooks/pre-commit.sample"
( cd "$ih" && bash "$kr/kit/hooks/install-githooks.sh" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "a *.sample hook does not count as an active hook" || bad "sample hooks"
out="$( cd "$ih" && rm -f kit/hooks/pre-push && bash "$kr/kit/hooks/install-githooks.sh" 2>&1 )"; rc=$?
{ [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'pre-push is missing'; } && ok "a missing hook file is named" || bad "missing hook file message ($rc)"
rm -rf "$ih"

echo "== gate-attest maps a recorded verdict to a commit status (fake gh)"
ga2="$(mktemp -d)"; mkdir -p "$ga2/bin" "$ga2/state"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE_GH_LOG"\n' > "$ga2/bin/gh"; chmod +x "$ga2/bin/gh"
git init -q -b main "$ga2/r"; mkdir -p "$ga2/r/ops"; printf '#!/bin/sh\n' > "$ga2/r/ops/local-ci.sh"; ( cd "$ga2/r" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m a ); gsha="$(git -C "$ga2/r" rev-parse HEAD)"
att() {   # att <scope> <result-line>: prints "<attest exit>:<state posted>"
  rm -f "$ga2/state/$gsha.json" "$ga2/log"
  ( cd "$ga2/r" && KIT_GATE_STATE_DIR="$ga2/state" KIT_GATE_RAN_ALL="$([ "$1" = all ] && echo 1)" bash "$kr/kit/ops/gate-record.sh" "$gsha" "$1" "$2" >/dev/null 2>&1 )
  ( cd "$ga2/r" && PATH="$ga2/bin:$PATH" FAKE_GH_LOG="$ga2/log" KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga2/state" bash "$kr/kit/ops/gate-attest.sh" "$gsha" >/dev/null 2>&1 ); local rc=$?
  echo "$rc:$(grep -o 'state=[a-z]*' "$ga2/log" 2>/dev/null | head -1)"
}
[ "$(att all 'RESULT: 5 passed, 0 failed, 0 skipped')" = "0:state=success" ] && ok "a full-gate pass is published as success" || bad "all pass -> success"
[ "$(att filtered 'RESULT: 5 passed, 0 failed, 0 skipped')" = "1:state=pending" ] && ok "a filtered pass is published as pending, never success" || bad "filtered pass -> pending"
[ "$(att filtered 'RESULT: 0 passed, 3 failed, 0 skipped')" = "1:state=failure" ] && ok "a failing gate is published as failure" || bad "fail -> failure"
[ "$(att none '')" = "1:state=failure" ] && ok "a gate that did not run is published as failure" || bad "none -> failure"
att all 'RESULT: 5 passed, 0 failed, 0 skipped' >/dev/null
blob12="$(git -C "$ga2/r" rev-parse HEAD:ops/local-ci.sh | cut -c1-12)"; tree12="$(git -C "$ga2/r" rev-parse 'HEAD^{tree}' | cut -c1-12)"
grep -q "| gate $blob12 | tree $tree12" "$ga2/log" && ok "the published description names the gate script and the tree the verdict is about" || bad "status description"
rm -f "$ga2/state/$gsha.json" "$ga2/log"; ( cd "$ga2/r" && KIT_GATE_STATE_DIR="$ga2/state" bash "$kr/kit/ops/gate-record.sh" "$gsha" filtered 'RESULT: 3 passed, 1 failed, 0 skipped' "$(printf 'x%.0s' $(seq 1 300))" >/dev/null 2>&1 )
( cd "$ga2/r" && PATH="$ga2/bin:$PATH" FAKE_GH_LOG="$ga2/log" KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga2/state" bash "$kr/kit/ops/gate-attest.sh" "$gsha" >/dev/null 2>&1 )
dlen="$(sed -n 's/.*description=//p' "$ga2/log" | tr -d '\n' | wc -c)"
{ [ "$dlen" -le 138 ] && [ "$dlen" -ge 100 ]; } && ok "a long reason is cut to fit GitHub's status description limit" || bad "status description length ($dlen)"
rm -f "$ga2/state/$gsha.json" "$ga2/log"
( cd "$ga2/r" && PATH="$ga2/bin:$PATH" FAKE_GH_LOG="$ga2/log" KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga2/state" bash "$kr/kit/ops/gate-attest.sh" "$gsha" >"$ga2/out" 2>&1 ); r1=$?
{ [ $r1 -eq 1 ] && grep -q 'NO RECORD' "$ga2/out" && [ ! -e "$ga2/log" ]; } && ok "no record for the commit means no status is published (exit 1)" || bad "attest without a record ($r1)"
( cd "$ga2/r" && PATH="$ga2/bin:$PATH" FAKE_GH_LOG="$ga2/log" KIT_GATE_STATE_DIR="$ga2/state" env -u KIT_GATE_REPO bash "$kr/kit/ops/gate-attest.sh" "$gsha" >"$ga2/out" 2>&1 ); r2=$?
( cd "$ga2/r" && PATH="$ga2/bin:$PATH" FAKE_GH_LOG="$ga2/log" KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga2/state" bash "$kr/kit/ops/gate-attest.sh" not-a-commit >/dev/null 2>&1 ); r3=$?
[ "$r2$r3" = 22 ] && grep -q KIT_GATE_REPO "$ga2/out" && ok "no KIT_GATE_REPO, or an argument that is not a commit, cannot attest (exit 2)" || bad "attest preconditions ($r2 $r3)"
mkdir -p "$ga2/badgh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$ga2/badgh/gh"; chmod +x "$ga2/badgh/gh"
( cd "$ga2/r" && KIT_GATE_STATE_DIR="$ga2/state" KIT_GATE_RAN_ALL=1 bash "$kr/kit/ops/gate-record.sh" "$gsha" all 'RESULT: 5 passed, 0 failed, 0 skipped' >/dev/null 2>&1 )
( cd "$ga2/r" && PATH="$ga2/badgh:$PATH" KIT_GATE_REPO=o/r KIT_GATE_STATE_DIR="$ga2/state" bash "$kr/kit/ops/gate-attest.sh" "$gsha" >"$ga2/out" 2>&1 ); r4=$?
{ [ $r4 -eq 1 ] && grep -q 'could not publish' "$ga2/out"; } && ok "a gh that fails is not a published status (exit 1)" || bad "attest with a failing gh ($r4)"
rm -rf "$ga2"

echo "== pre-commit"
t2="$(mktemp -d)"; git init -q -b main "$t2"; mkdir -p "$t2/kit/hooks"; cp kit/hooks/pre-commit "$t2/kit/hooks/"
( cd "$t2" && git config core.hooksPath kit/hooks && echo a > f && git add f && KIT_SHARED_TREE_PATH="$t2" git -c user.name=t -c user.email=t@t commit -q -m a >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "refuses commit from shared tree" || bad "refuses commit from shared tree"
( cd "$t2" && KIT_SHARED_TREE_PATH=/nonexistent git -c user.name=t -c user.email=t@t commit -q -m a >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "refuses commit to main" || bad "refuses commit to main"
( cd "$t2" && git config kit.shared-tree "$t2" && git checkout -q -b cfg/task && git -c user.name=t -c user.email=t@t commit -q -m a >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "shared tree via git config is honored" || bad "shared tree via git config is honored"
( cd "$t2" && git config --unset kit.shared-tree && git checkout -q main )
( cd "$t2" && git checkout -q -b agent/task && KIT_SHARED_TREE_PATH=/nonexistent git -c user.name=t -c user.email=t@t commit -q -m a >/dev/null 2>&1 ); [ $? -eq 0 ] && ok "allows branch commit in a worktree" || bad "allows branch commit in a worktree"
t3="$(mktemp -d)"; git init -q -b main "$t3"; mkdir -p "$t3/kit/hooks"; cp kit/hooks/pre-commit "$t3/kit/hooks/"; git -C "$t3" config core.hooksPath kit/hooks; echo a > "$t3/f"; git -C "$t3" add f
pc() { ( cd "$t3" && env KIT_SHARED_TREE_PATH=/nonexistent "$@" git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a >"$t3/out" 2>&1 ); echo $?; }
[ "$(pc)" != 0 ] && grep -q "Refusing to commit directly to 'main'" "$t3/out" && grep -q 'KIT_ALLOW_MAIN_COMMIT=1' "$t3/out" && ok "a commit on main is refused, and the message says how to override it" || bad "main refusal text"
[ "$(pc KIT_ALLOW_MAIN_COMMIT=1)" = 0 ] && grep -q 'WARNING: allowing direct commit to main' "$t3/out" && ok "KIT_ALLOW_MAIN_COMMIT=1 allows it, loudly" || bad "main override"
[ "$(pc KIT_ALLOW_MAIN_COMMIT=1)" = 0 ] && grep -q 'INACTIVE' "$t3/out" && ok "with no shared checkout configured the guard says it is inactive" || bad "inactive shared-tree warning"
git -C "$t3" checkout -q -b agent/x
( cd "$t3" && env KIT_SHARED_TREE_PATH="$t3" git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a >"$t3/out" 2>&1 ); r1=$?
( cd "$t3" && env KIT_SHARED_TREE_PATH="$t3" KIT_ALLOW_SHARED_TREE=1 git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a >"$t3/out2" 2>&1 ); r2=$?
{ [ $r1 -ne 0 ] && grep -q 'shared canonical checkout' "$t3/out" && [ $r2 -eq 0 ] && grep -q 'WARNING: allowing commit from the shared checkout' "$t3/out2"; } && ok "the shared checkout refusal names itself and its override, and the override warns" || bad "shared checkout messages ($r1 $r2)"

echo "== honesty-marker parser: only the first line of a comment is ever read"
mp() { printf '%b' "$1" | LC_ALL=C awk -f kit/ops/marker-parse.awk | grep -c '^GATE-REVIEW:'; }   # live markers
sp() { printf '%b' "$1" | LC_ALL=C awk -f kit/ops/marker-parse.awk | grep -c '^STRAY'; }          # look-alikes reported
# Table-driven: every decoration, separator and spelling that makes a line marker-shaped, one at a time, with
# a payload that holds none of reject/approve/block/hex, so only the marker-shaped rule can report it.
deco_ok=1
for pre in ' ' '\t' '> ' '* ' '_' '# ' '- ' '+ ' '~' '`' '(' ')' '[' ']' '.' '7' '\xef\xbb\xbf'; do
  [ "$(sp "x\n${pre}GATE-REVIEW: ok\n")" = 1 ] || { deco_ok=0; echo "  not reported with the prefix: $pre"; }
done
for sep in ' ' '\t' '*' '_' '`' ' **'; do
  [ "$(sp "x\nGATE-REVIEW${sep}: ok\n")" = 1 ] || { deco_ok=0; echo "  not reported with the separator: $sep"; }
done
for name in gate-review gate_review Gate_Review GATE_REVIEW; do
  [ "$(sp "x\n${name}: ok\n")" = 1 ] || { deco_ok=0; echo "  not reported with the spelling: $name"; }
done
[ $deco_ok -eq 1 ] && ok "a line that starts like a marker is reported whatever decorates it, however the name is spelled and whatever sits before the colon" || bad "marker-shaped line not reported"
shape_ok=1
for body in 'x\nGATE-REVIEW is a gate\n' 'x\nsee gate-review: the docs\n' 'x\n a mention of gate-review and the rest\n' 'x\nGATE-REVIEWS: ok\n' 'x\nreview: gate\n'; do
  [ "$(sp "$body")" = 0 ] || { shape_ok=0; echo "  reported but harmless: $body"; }
done
[ $shape_ok -eq 1 ] && ok "a mention that is not marker-shaped is not reported: no colon, nothing after it that names a verdict, or another word" || bad "harmless mention reported"
mid_ok=1
for body in 'x\nPer the gate-review process, GATE-REVIEW: s2 reject abc\n' \
            'x\nsee gate_review notes then gate-review: s reject y\n' \
            'x\nthe gate-review: notes then gate_review: s2 approve\n' \
            'x\nsee gate-review: abcdef0 and more\n' \
            'x\nsee gate-review: this will block it\n' \
            'x\nsee gate-review and gate_review and gate-review: approve\n'; do
  [ "$(sp "$body")" = 1 ] || { mid_ok=0; echo "  verdict hidden: $body"; }
done
[ $mid_ok -eq 1 ] && ok "a verdict after an earlier harmless mention of the name on the same line is still reported, in either spelling and order" || bad "a mention hid a verdict"
[ "$(mp 'GATE-REVIEW: s1 approve checked tests\n')" = 1 ] && ok "a first-line marker is live" || bad "first-line marker"
[ "$(mp 'GATE-REVIEW: s1 approve x\r\n')" = 1 ] && ok "a CRLF first line is live" || bad "CRLF first line"
[ "$(mp 'GATE-REVIEW: s1 approve x <!--\nhidden\n-->\n')" = 1 ] && ok "a first-line marker before a same-line comment start is live" || bad "marker before a comment start"
[ "$(printf 'GATE-REVIEW: s1 approve x <!-- GATE-REVIEW: s2 reject y -->\n' | LC_ALL=C awk -f kit/ops/marker-parse.awk)" = 'GATE-REVIEW: s1 approve x ' ] && ok "only the visible text before a same-line comment start is returned" || bad "same-line comment text returned"
[ "$(mp 'GATE-REVIEW: s1 approve note mentions <pre> and <details> inline\n')" = 1 ] && ok "tags mentioned in the note do not hide the marker" || bad "tags in the note"
[ "$(mp 'GATE-REVIEW: s1 approve x\nGATE-REVIEW: s2 reject y\n')" = 2 ] && ok "a second marker line after a live first line is reported, so the check can refuse the ambiguity" || bad "second marker line"
[ "$(mp 'GATE-REVIEW: s1 approve x\rGATE-REVIEW: s2 reject y\n')" = 2 ] && ok "a bare carriage return counts as a line break" || bad "bare CR second marker"
[ "$(mp 'note\nGATE-REVIEW: s1 approve x\nGATE-REVIEW: s2 reject y\n')" = 0 ] && ok "and nothing is read when the first line is not a marker" || bad "no marker on line one"
inert_ok=1
for body in \
  'text\nGATE-REVIEW: s1 approve x\n' \
  '\nGATE-REVIEW: s1 approve x\n' \
  ' GATE-REVIEW: s1 approve x\n' \
  '> GATE-REVIEW: s1 approve x\n' \
  '> quoted\nGATE-REVIEW: s1 approve x\n' \
  '```\nGATE-REVIEW: s1 approve x\n```\n' \
  '~~~\nGATE-REVIEW: s1 approve x\n~~~\n' \
  '<!--\nGATE-REVIEW: s1 approve x\n-->\n' \
  '<pre>\nGATE-REVIEW: s1 approve x\n</pre>\n' \
  '<details>\nGATE-REVIEW: s1 approve x\n</details>\n' \
  '[a]: http://x "\nGATE-REVIEW: s1 approve x\n"\n' \
  '<?x\nGATE-REVIEW: s1 approve x\n?>\n' \
  '<!X\nGATE-REVIEW: s1 approve x\n>\n' \
  '<![CDATA[\nGATE-REVIEW: s1 approve x\n]]>\n' \
  '<div\nGATE-REVIEW: s1 approve x\n>\n' \
  'GATE\xe2\x80\x91REVIEW: s1 approve x\n' \
  '\xef\xbb\xbfGATE-REVIEW: s1 approve x\n'; do
  [ "$(mp "$body")" = 0 ] || { inert_ok=0; echo "  live when it must be inert: $body"; }
done
[ $inert_ok -eq 1 ] && ok "a marker that is not the first line is inert: fences, quotes, comments, pre, details, link definitions, PI, declarations, CDATA, open tags, indentation, BOM, lookalikes" || bad "a marker that is not the first line was live"
lk_ok=1
for body in \
  'text\nGATE-REVIEW: s1 approve x\n' ' GATE-REVIEW: s1 reject x\n' '> GATE-REVIEW: s1 reject x\n' '**GATE-REVIEW:** s1 reject x\n' \
  '\xef\xbb\xbfGATE-REVIEW: s1 reject x\n' 'gate-review: s1 reject x\n' '- GATE-REVIEW: s1 reject x\n' '1. GATE-REVIEW: s1 reject x\n' \
  '_GATE_REVIEW_: s1 reject x\n' 'GATE-REVIEW : s1 reject x\n' 'GATE-REVIEW\t: s1 reject x\n' '```\nGATE-REVIEW: s1 reject x\n```\n' 'GATE-REVIEW: s1 approve x\n  GATE-REVIEW: s2 reject y\n'; do
  [ "$(sp "$body")" -ge 1 ] || { lk_ok=0; echo "  not reported: $body"; }
done
[ $lk_ok -eq 1 ] && ok "a line that looks like a marker but is not live is reported, so a misplaced reject cannot vanish" || bad "a marker-shaped line was not reported"
quiet_ok=1
for body in 'I will post the GATE-REVIEW after lunch\n' 'GATE-REVIEW marker is needed\n' 'see GATE-REVIEW: below\n' 'Gate review passed.\n' 'GATE-REVIEW: s1 approve x\nthe GATE-REVIEW above\n'; do
  [ "$(sp "$body")" = 0 ] || { quiet_ok=0; echo "  reported: $body"; }
done
[ $quiet_ok -eq 1 ] && ok "a mention in the middle of a sentence is not reported" || bad "a prose mention was reported"
[ "$(sp '**GATE-REVIEW**: s1 reject x\n')" -ge 1 ] && [ "$(sp '`GATE-REVIEW`: s1 reject x\n')" -ge 1 ] && ok "emphasis or code marks that close before the colon do not hide a marker-shaped line" || bad "emphasis closing before the colon"
[ "$(sp 'GATE\xe2\x80\x91REVIEW: s1 reject x\n')" = 0 ] && ok "a non-breaking-hyphen spelling is not detected (documented limit: the parser reads ASCII)" || bad "look-alike spelling detected"
awk_ref=""; awk_n=0
for impl in gawk mawk "busybox awk" nawk; do
  command -v "${impl%% *}" >/dev/null 2>&1 || continue
  out=""
  for body in 'GATE-REVIEW: s1 approve x\n' 'note\nGATE-REVIEW: s1 approve x\n' ' GATE-REVIEW: s1 reject x\n' '**GATE-REVIEW:** s1 reject x\n' '\xef\xbb\xbfGATE-REVIEW: s1 approve x\n' \
              'GATE-REVIEW: s1 approve x\rGATE-REVIEW: s2 reject y\n' 'GATE-REVIEW: s1 approve x <!-- hidden -->\n' 'I posted a GATE-REVIEW above\n' '1. GATE-REVIEW: s1 reject x\n'; do
    out="$out$(printf '%b' "$body" | LC_ALL=C $impl -f kit/ops/marker-parse.awk 2>&1 | tr '\n' '|')"$'\n'
  done
  awk_n=$((awk_n+1)); [ -n "$awk_ref" ] || awk_ref="$out"
  [ "$out" = "$awk_ref" ] || { echo "  $impl disagrees with the first awk"; awk_ref="DISAGREE"; }
done
[ "$awk_ref" != DISAGREE ] && [ "$awk_n" -ge 1 ] && ok "the parser gives the same answers under every awk installed here ($awk_n)" || bad "awk implementations disagree"

echo "== premerge-check end to end (fake gh): an approval names the whole head commit"
pm="$(mktemp -d)"; mkdir -p "$pm/bin" "$pm/repo"
cat > "$pm/bin/gh" <<'GH'
#!/usr/bin/env bash
[ -z "${FAKE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"--json headRefOid"*) [ "${FAKE_HEAD_FAIL:-0}" = 1 ] && exit 1; printf '{"headRefOid":"%s"}\n' "$FAKE_HEAD" ;;
  *"--json comments"*) [ "${FAKE_COMMENTS_FAIL:-0}" = 1 ] && exit 1; cat "$FAKE_COMMENTS" ;;
  *"/status"*)
    [ "${FAKE_STATUS_FAIL:-0}" = 1 ] && exit 1
    [ "${FAKE_STATUS_JUNK:-0}" = 1 ] && { echo 'not json'; exit 0; }
    if [ -n "${FAKE_GATE_STATE:-}" ]; then printf '{"statuses":[{"context":"local-ci/gate","state":"%s"}]}\n' "$FAKE_GATE_STATE"; else echo '{"statuses":[]}'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
GH
chmod +x "$pm/bin/gh"
# The check reads no git history, so the head is a fixed, well-formed commit id that contains letters.
pm_head="3f2a9c1e5d7b4a60918273645f0e1d2c3b4a5968"; H7="${pm_head:0:7}"; H12="${pm_head:0:12}"
twin="${H7}$(printf '%033d' 0 | tr 0 b)"        # a different commit that shares the first seven characters
other="$(printf '%040d' 0 | tr 0 b)"            # a well-formed commit id that is not the head
UP="$(printf '%s' "$pm_head" | tr a-f A-F)"
pmjson() {   # pmjson <spec>...: each spec is "flags@@body"; flags: min, edited, an association such as NONE (default OWNER),
             # by:<login>, at:<time>, review:<STATE> (a native review instead of a comment)
  python3 -c 'import sys, json
comments, reviews = [], []
for spec in sys.argv[1:]:
    flags, _, body = spec.partition("@@")
    f = [x for x in flags.split(",") if x]
    assoc = next((x for x in f if x.isupper()), "OWNER")
    author = {"login": next((x[3:] for x in f if x.startswith("by:")), "alice")}
    at = next((x[3:] for x in f if x.startswith("at:")), "2026-09-24T02:00:00Z")
    state = next((x[7:] for x in f if x.startswith("review:")), None)
    if state:
        reviews.append({"authorAssociation": assoc, "author": author, "body": body, "includesCreatedEdit": "edited" in f, "state": state, "submittedAt": at})
    else:
        c = {"createdAt": at, "authorAssociation": assoc, "author": author, "url": "https://github.com/o/r/pull/1#issuecomment-1", "isMinimized": "min" in f, "includesCreatedEdit": "edited" in f, "body": body}
        if "noassoc" in f: del c["authorAssociation"]
        if "nullassoc" in f: c["authorAssociation"] = None
        comments.append(c)
print(json.dumps({"comments": comments, "reviews": reviews}))' "$@" > "$pm/comments.json"; }
pmrun() {   # pmrun <merger-session>: prints the exit code, output stays in $pm/out
  ( cd "$pm/repo" && PATH="$pm/bin:$PATH" FAKE_HEAD="${PM_HEAD:-$pm_head}" FAKE_GATE_STATE="${PM_STATE-success}" FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" "${PM_PR:-1}" --as "$1" >"$pm/out" 2>&1 ); echo $?
}
ap="@@GATE-REVIEW: reviewer-session approve $pm_head checked it"
pmjson "$ap"
[ "$(pmrun merger-session)" = 0 ] && grep -q 'may be merged' "$pm/out" && ok "an approval that names the whole head commit passes" || bad "approval naming the head"
grep -q -- "--match-head-commit $pm_head" "$pm/out" && ok "and the output says how to merge exactly that commit" || bad "match-head-commit line"
abbrev_ok=1
for sh in "$H7" "$H12" "${pm_head:0:39}"; do
  pmjson "@@GATE-REVIEW: reviewer-session approve $sh checked it"
  { [ "$(pmrun merger-session)" = 1 ] && grep -q 'abbreviation' "$pm/out"; } || { abbrev_ok=0; echo "  accepted an abbreviation of ${#sh} characters"; }
done
[ $abbrev_ok -eq 1 ] && ok "an approval that abbreviates the head commit is refused, whatever the length" || bad "abbreviated approval accepted"
pmjson "@@GATE-REVIEW: reviewer-session approve $twin reviewed a commit that shares the first seven characters"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'names the head commit' "$pm/out" && ok "an approval for another commit with the same first seven characters does not carry over" || bad "seven-character twin as the approved commit"
pmjson "$ap"
[ "$(PM_HEAD=$twin pmrun merger-session)" = 1 ] && ok "and an approval does not carry to a head that shares only its first seven characters" || bad "seven-character twin as the head"
pmjson "@@GATE-REVIEW: reviewer-session approve $other reviewed an older commit"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'names the head commit' "$pm/out" && ok "an approval that names another commit is refused (it reviewed different code)" || bad "approval naming another commit"
pmjson '@@GATE-REVIEW: reviewer-session approve checked it'
[ "$(pmrun merger-session)" = 1 ] && ok "an approval that names no commit is refused" || bad "approval naming no commit"
pmjson "@@GATE-REVIEW: reviewer-session approve ${H7:0:6} too short"
[ "$(pmrun merger-session)" = 1 ] && ok "a commit id shorter than 7 characters is refused" || bad "short id"
pmjson "@@GATE-REVIEW: reviewer-session approve $UP shouting"
[ "$(pmrun merger-session)" = 1 ] && ok "an uppercase commit id is refused" || bad "uppercase id"
pmjson "@@GATE-REVIEW: same-session approve $pm_head mine"
[ "$(pmrun same-session)" = 1 ] && grep -q 'Self-review' "$pm/out" && ok "self-review is refused" || bad "self-review"
[ "$(pmrun Same-Session)" = 1 ] && ok "self-review is refused when only the case differs" || bad "self-review by case"
self_ok=1
for v in 'same-session.' 'same_session' '.same-session' 'same-session:' 'SAME-SESSION'; do
  pmjson "@@GATE-REVIEW: $v approve $pm_head mine"
  [ "$(pmrun same-session)" = 1 ] || { self_ok=0; echo "  counted as another session: $v"; }
done
[ $self_ok -eq 1 ] && ok "self-review is refused when the ids differ only by case or punctuation" || bad "self-review by punctuation"
pmjson "@@GATE-REVIEW: a-reviewer approve $pm_head x" "@@GATE-REVIEW: b-reviewer approve $pm_head y"
[ "$(pmrun merger-session)" = 0 ] && ok "approvals from two other sessions pass" || bad "two approvals"
pmjson "@@GATE-REVIEW: merger-session approve $pm_head mine" "@@GATE-REVIEW: a-reviewer approve $pm_head y"
[ "$(pmrun merger-session)" = 0 ] && ok "the merger's own approval is ignored and another session's still counts" || bad "own plus other approval"
pmjson "@@GATE-REVIEW: a-reviewer approve $pm_head x"$'\n'"GATE-REVIEW: b-reviewer approve $pm_head y"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'more than one GATE-REVIEW marker' "$pm/out" && ok "two markers in one comment are refused as ambiguous" || bad "two markers in one comment"
pmjson "@@GATE-REVIEW: reviewer-session reject $pm_head broken"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'not approve' "$pm/out" && ok "a reject is refused" || bad "reject"
pmjson "@@GATE-REVIEW: a-reviewer reject $H7 broken (short id)" "$ap"
[ "$(pmrun merger-session)" = 1 ] && ok "a reject that abbreviates the head still blocks an approval of the whole id" || bad "short reject against a full approval"
pmjson "@@GATE-REVIEW: reviewer-session reject $other old head" "@@GATE-REVIEW: reviewer-session approve $pm_head new head"
[ "$(pmrun merger-session)" = 0 ] && ok "a reject of an old commit plus an approval of the head passes: the old reject is stale" || bad "stale reject plus fresh approve"
pmjson "$ap"
[ "$(PM_STATE='' pmrun merger-session)" = 1 ] && grep -q 'no local-ci/gate status' "$pm/out" && ok "a missing gate status is refused even with a valid marker" || bad "missing gate status"
[ "$(PM_STATE=failure pmrun merger-session)" = 1 ] && ok "a failing gate status is refused" || bad "failing gate status"
[ "$(PM_STATE=pending pmrun merger-session)" = 1 ] && grep -q 'FAIL' "$pm/out" && ok "a pending gate status is not a pass: only success is" || bad "pending gate status"
[ "$(PM_STATE=error pmrun merger-session)" = 1 ] && ok "and an error status is refused" || bad "error gate status"
[ "$(FAKE_STATUS_FAIL=1 pmrun merger-session)" = 2 ] && grep -q 'cannot read the commit status' "$pm/out" && ok "a failing status call cannot attest, with the message that names the failed read" || bad "status call failing"
[ "$(FAKE_STATUS_JUNK=1 pmrun merger-session)" = 2 ] && ok "an unparseable status cannot attest" || bad "status unparseable"
for badid in '<session-id>' 'révieweur' 'ab' 'unknown-session' 'none' '1234567' 'None.' 'unknown_session' 'TEST'; do
  pmjson "@@GATE-REVIEW: $badid approve $pm_head x"
  [ "$(pmrun merger-session)" = 1 ] || { echo "  accepted reviewer id: $badid"; bad "unusable reviewer id"; }
done; ok "placeholder, non-ASCII, too-short, reserved and letterless reviewer ids are refused"
pmjson "@@GATE-REVIEW: reviewer-session approve $pm_head"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'needs a note' "$pm/out" && ok "a marker with no note is refused" || bad "marker with no note"
echo "-- rejects are never lost"
rej_ok=1
for v in "Reject $pm_head" "REJECT $pm_head" "rejected $pm_head" "block $pm_head" "changes-requested $pm_head" "no $pm_head" "reject: $pm_head" "reject $pm_head," "reject ($pm_head)" "reject sha=$pm_head" "reject $UP" "reject ${pm_head:0:6}" "reject found a race"; do
  pmjson "@@GATE-REVIEW: a-reviewer $v broken" "$ap"
  [ "$(pmrun merger-session)" = 1 ] || { rej_ok=0; echo "  did not block: $v"; }
done
[ $rej_ok -eq 1 ] && ok "a reject spelled any other way (case, punctuation, short or missing id) still blocks: only a clear approval or a clearly stale marker is ignored" || bad "a misspelled reject was dropped"
mute_ok=1
for v in Reject REJECT rejected block changes-requested reject; do for fl in edited min; do
  pmjson "$fl@@GATE-REVIEW: a-reviewer $v $pm_head broken" "$ap"
  [ "$(pmrun merger-session)" = 1 ] || { mute_ok=0; echo "  $fl '$v' stopped blocking"; }
done; done
[ $mute_ok -eq 1 ] && ok "an edited or minimized reject, in any spelling, still blocks: only an approval is ever muted" || bad "an edited or minimized reject was dropped"
pmjson "edited@@GATE-REVIEW: reviewer-session approve $pm_head edited later"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'edited or minimized' "$pm/out" && ok "an edited approval is not trusted" || bad "edited approval"
pmjson "min@@GATE-REVIEW: reviewer-session approve $pm_head hidden"
[ "$(pmrun merger-session)" = 1 ] && ok "a minimized approval is not trusted" || bad "minimized approval"
pmjson "min@@GATE-REVIEW: a-reviewer reject $pm_head broken" "@@GATE-REVIEW: b-reviewer approve $pm_head fine"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'not approve' "$pm/out" && ok "a minimized reject still blocks (it is never dropped)" || bad "minimized reject blocks"
pmjson "@@GATE-REVIEW: reviewer-session approve $pm_head fine"$'\n'"filler"$'\n'"GATE-REVIEW: other-reviewer reject $pm_head broken"
[ "$(pmrun merger-session)" = 1 ] && ok "a reject later in the same comment cannot be hidden behind an approve on line one" || bad "second marker in one comment"
pmjson "@@GATE-REVIEW: reviewer-session approve $pm_head fine"$'\r'"GATE-REVIEW: other-reviewer reject $pm_head broken"
[ "$(pmrun merger-session)" = 1 ] && ok "nor behind a bare carriage return" || bad "CR second marker"
stray_ok=1
for v in " GATE-REVIEW: a-reviewer reject $pm_head x" "> GATE-REVIEW: a-reviewer reject $pm_head x" "**GATE-REVIEW:** a-reviewer reject $pm_head x" $'\xef\xbb\xbf'"GATE-REVIEW: a-reviewer reject $pm_head x" "gate-review: a-reviewer reject $pm_head x" "- GATE-REVIEW: a-reviewer reject $pm_head x" "Looks wrong."$'\n'"GATE-REVIEW: a-reviewer reject $pm_head x"; do
  pmjson "@@$v" "$ap"
  { [ "$(pmrun merger-session)" = 1 ] && grep -q 'not the first line' "$pm/out"; } || { stray_ok=0; echo "  not refused: $v"; }
done
[ $stray_ok -eq 1 ] && ok "a reject that looks like a marker but is indented, quoted, bold, bulleted, lower case or on a later line is refused, never ignored" || bad "a misplaced reject was ignored"
pmjson '@@note first'$'\n''GATE-REVIEW: reviewer-session approve '"$pm_head"' x'
[ "$(pmrun merger-session)" = 1 ] && ok "a marker that is not the first line is not an approval" || bad "marker not on the first line"
pmjson "@@Thanks for the review. The GATE-REVIEW marker is above." "$ap"
[ "$(pmrun merger-session)" = 0 ] && ok "a mention of GATE-REVIEW in the middle of a sentence neither counts nor blocks" || bad "prose mention blocked the merge"
echo "-- stale and stray, round four"
ok_ap="$ap"
nearmiss="${pm_head:0:39}0"; longer="${pm_head}a"; sixtyfour="${pm_head}$(printf 'c%.0s' $(seq 1 24))"
stale_ok=1
for v in "reject $nearmiss breaks prod" "reject $longer breaks prod" "reject $sixtyfour breaks prod" "reject defaced the auth check" "reject deadbeef breaks prod"; do
  pmjson "@@GATE-REVIEW: carol-reviewer $v" "$ok_ap"
  [ "$(pmrun merger-session)" = 1 ] || { stale_ok=0; echo "  a veto was lost: $v"; }
done
[ $stale_ok -eq 1 ] && ok "a reject is stale only when it names a full-length id far from the head: a typo, an extra character, a 64-character id that starts with the head, a note word that looks like hex, and an abbreviation all still block" || bad "a reject was wrongly treated as stale"
pmjson "@@GATE-REVIEW: carol-reviewer reject $other old head" "$ok_ap"
[ "$(pmrun merger-session)" = 0 ] && ok "a reject of a clearly different full commit is stale and does not block" || bad "stale reject"
stray_ok=1
for v in "$(printf '\xf0\x9f\x9a\xab') GATE-REVIEW: carol-reviewer reject $pm_head x" "$(printf '\xe2\x80\xa2') GATE-REVIEW: carol-reviewer reject $pm_head x" "| GATE-REVIEW: carol-reviewer reject $pm_head x" "<b>GATE-REVIEW: carol-reviewer reject $pm_head x</b>" "Verdict: GATE-REVIEW: carol-reviewer reject $pm_head x" "@carol GATE-REVIEW: carol-reviewer reject $pm_head x"; do
  pmjson "@@$v" "$ok_ap"
  { [ "$(pmrun merger-session)" = 1 ] && grep -q 'not the first line' "$pm/out"; } || { stray_ok=0; echo "  a reject slipped past: $v"; }
done
[ $stray_ok -eq 1 ] && ok "a reject behind an emoji, a bullet, a pipe, a tag, a label or a mention is refused, not ignored" || bad "decorated reject ignored"
pmjson "@@> GATE-REVIEW: carol-reviewer reject $other old head"$'\n'"Fixed in the new commit." "$ok_ap"
[ "$(pmrun merger-session)" = 0 ] && ok "quote-replying a reject of an older commit does not block the merge" || bad "quoted stale reject"
pmjson "@@> GATE-REVIEW: carol-reviewer reject $pm_head still broken" "$ok_ap"
[ "$(pmrun merger-session)" = 1 ] && ok "but quoting a reject of THIS commit does" || bad "quoted live reject"
pmjson "@@premerge output:"$'\n'"         GATE-REVIEW: <its-session-id> approve $pm_head <what it actually checked>" "$ok_ap"
[ "$(pmrun merger-session)" = 0 ] && ok "the check's own usage line, pasted into a comment, is not a marker" || bad "pasted usage line"
pmjson "@@Please add a GATE-REVIEW marker before merging." "$ok_ap"
[ "$(pmrun merger-session)" = 0 ] && ok "a sentence that merely mentions GATE-REVIEW is left alone" || bad "prose mention"
pmjson "@@GATE-REVIEW: reviewer-session approve $pm_head fine"$'\xe2\x80\xa8'"GATE-REVIEW: carol-reviewer reject $pm_head bad"
[ "$(pmrun merger-session)" = 1 ] && ok "a reject after a Unicode line separator cannot hide inside an approval's line" || bad "U+2028 hiding"
pmjson "@@GATE-REVIEW:reviewer-session approve $pm_head ok"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'malformed' "$pm/out" && grep -q 'delete that comment and post a new one' "$pm/out" && ok "a glued colon is called malformed, and the output says to repost, not edit" || bad "malformed message"
pmjson "edited@@GATE-REVIEW: reviewer-session approve $pm_head edited later"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'delete that comment and post a new one' "$pm/out" && ok "an edited approval is not repaired by editing, and the output says so" || bad "repost hint for an edited approval"
pmjson "$ap" "review:CHANGES_REQUESTED,by:foobot,MEMBER@@fix" "review:APPROVED,by:foo[bot],at:2026-09-24T04:00:00Z,MEMBER@@fine"
[ "$(pmrun merger-session)" = 1 ] && ok "two accounts whose logins look alike once cleaned do not clear each other's request for changes" || bad "login collision"
pmjson "$ap" "review:APPROVED,MEMBER@@looks good"
[ "$(pmrun merger-session)" = 0 ] && ok "a native Approve review neither blocks nor is needed beside a marker" || bad "native approve beside a marker"
pmjson "review:APPROVED,MEMBER@@looks good"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'no GATE-REVIEW marker' "$pm/out" && ok "and a native Approve review alone is not an approval here" || bad "native approve alone"
pmjson "@@thanks $(printf '\xe2\x9c\x93') nice work" "$ap"
( cd "$pm/repo" && PYTHONUTF8=0 PYTHONIOENCODING=ascii PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >"$pm/out" 2>&1 ); [ $? -eq 0 ] && ok "a non-ASCII character in any comment does not freeze the check, whatever the caller's Python encoding settings" || bad "non-ASCII comment"
rm -f "$pm/gh.log"; pmjson "$ap"; ( cd "$pm/repo" && FAKE_GH_LOG="$pm/gh.log" PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >/dev/null 2>&1 )
grep -q 'status?per_page=100' "$pm/gh.log" && ok "the commit status is requested with a page size that holds every context" || bad "status page size"
( cd "$pm/repo" && PATH="$pm/bin:$PATH" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 2 --as merger-session >"$pm/out" 2>&1 ); r1=$?
{ [ $r1 -eq 2 ] && grep -q 'one PR number only' "$pm/out"; } && ok "a second PR number is a usage error, not a silent switch to the later one" || bad "second positional ($r1)"
ln -s "$kr/kit/ops/premerge-check.sh" "$pm/link.sh"; pmjson "$ap"
( cd "$pm/repo" && PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$pm/link.sh" 1 --as merger-session >"$pm/out" 2>&1 ); [ $? -eq 0 ] && ok "a symlink to the script finds marker-parse.awk beside the real file" || bad "symlinked script"
mkdir -p "$pm/badawk" "$pm/badb64"; printf '#!/bin/sh\nexit 2\n' > "$pm/badawk/awk"; printf '#!/bin/sh\nexit 1\n' > "$pm/badb64/base64"; chmod +x "$pm/badawk/awk" "$pm/badb64/base64"
( cd "$pm/repo" && PATH="$pm/badawk:$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >"$pm/out" 2>&1 ); r1=$?
( cd "$pm/repo" && PATH="$pm/badb64:$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >"$pm/out2" 2>&1 ); r2=$?
{ [ "$r1$r2" = 22 ] && grep -q 'parser failed' "$pm/out" && grep -q 'cannot decode' "$pm/out2"; } && ok "a parser or decoder that fails cannot attest (exit 2), instead of reading as 'no markers'" || bad "failing awk or base64 ($r1 $r2)"
xp2="$(mktemp -d)"; for tool in bash python3 gh grep sed env cat tr cut head tail sort wc dirname basename mkdir rm mktemp base64; do ln -s "$(command -v $tool)" "$xp2/$tool" 2>/dev/null; done; ln -sf "$pm/bin/gh" "$xp2/gh"
( cd "$pm/repo" && PATH="$xp2" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >"$pm/out" 2>&1 ); [ $? -eq 2 ] && grep -q 'awk is not installed' "$pm/out" && ok "a machine without awk cannot attest, and the output names the missing tool" || bad "missing awk"
echo "-- who counts"
pmjson "NONE@@GATE-REVIEW: reviewer-session approve $pm_head from an outsider"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'without OWNER, MEMBER or COLLABORATOR association were ignored' "$pm/out" && ok "a comment from someone without OWNER, MEMBER or COLLABORATOR association is ignored" || bad "outsider comment"
for fl in noassoc nullassoc; do
  pmjson "$fl@@GATE-REVIEW: reviewer-session approve $pm_head from nobody we know"
  { [ "$(pmrun merger-session)" = 1 ] && grep -q 'were ignored' "$pm/out"; } || bad "a comment with $fl was trusted"
done; ok "a comment whose association is missing or null is ignored, never trusted"
for assoc in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER NONE; do
  pmjson "$assoc@@GATE-REVIEW: reviewer-session approve $pm_head from an outsider"
  [ "$(pmrun merger-session)" = 1 ] || { echo "  an approval from $assoc counted"; assoc_bad=1; }
done
[ "${assoc_bad:-0}" = 0 ] && ok "an approval from a contributor, a first-timer or anyone with no association does not count" || bad "outsider approval counted"
unset assoc_bad
pmjson "MEMBER@@GATE-REVIEW: reviewer-session approve $pm_head from an org member"
[ "$(pmrun merger-session)" = 0 ] && ok "a MEMBER approval counts: association is not a permission check, and the docs say so" || bad "MEMBER approval"
pmjson "$ap" "review:CHANGES_REQUESTED,by:carol,MEMBER@@please fix the race"
[ "$(pmrun merger-session)" = 1 ] && grep -q 'native review' "$pm/out" && ok "a trusted reviewer's native 'Request changes' blocks" || bad "native request for changes"
pmjson "$ap" "review:CHANGES_REQUESTED,by:carol,at:2026-09-24T03:00:00Z,MEMBER@@fix" "review:APPROVED,by:carol,at:2026-09-24T04:00:00Z,MEMBER@@fixed"
[ "$(pmrun merger-session)" = 0 ] && ok "and a later native approval from the same reviewer clears it" || bad "later native approval"
pmjson "$ap" "review:CHANGES_REQUESTED,by:carol,at:2026-09-24T03:00:00Z,MEMBER@@fix" "review:COMMENTED,by:carol,at:2026-09-24T04:00:00Z,MEMBER@@a comment"
[ "$(pmrun merger-session)" = 1 ] && ok "but a later plain comment review does not" || bad "later comment review cleared the request"
pmjson "$ap" "review:CHANGES_REQUESTED,by:carol,at:2026-09-24T03:00:00Z,MEMBER@@fix" "review:DISMISSED,by:carol,at:2026-09-24T04:00:00Z,MEMBER@@x"
[ "$(pmrun merger-session)" = 0 ] && ok "and a dismissed review no longer blocks" || bad "dismissed review"
pmjson "$ap" "review:CHANGES_REQUESTED,by:dave,CONTRIBUTOR@@drive-by"
[ "$(pmrun merger-session)" = 0 ] && ok "a request for changes from an outsider is ignored like any outsider comment" || bad "outsider review"
pmjson "$ap" "review:COMMENTED,by:carol,MEMBER@@GATE-REVIEW: carol-reviewer reject $pm_head bad"
[ "$(pmrun merger-session)" = 1 ] && ok "a reject posted as a review body blocks" || bad "reject in a review body"
echo "-- robustness"
pmjson "@@GATE-REVIEW: reviewer-session approve $pm_head fine"$'\r'$'\n'"details"
[ "$(pmrun merger-session)" = 0 ] && ok "a CRLF comment still passes" || bad "CRLF comment passes"
pmjson "@@GATE-REVIEW: reviewer-session approve $pm_head fine <!-- hidden -->"
[ "$(pmrun merger-session)" = 0 ] && ok "text after a same-line HTML comment start is not part of the marker" || bad "same-line comment start"
pmjson "@@GATE-REVIEW: rev"$'\x1b'"[31mX approve $pm_head x"
[ "$(pmrun merger-session)" = 1 ] && ! LC_ALL=C grep -q $'\x1b' "$pm/out" && ok "terminal escapes from a comment never reach the output" || bad "escape sequences echoed"
pmjson "$ap"
[ "$(FAKE_HEAD_FAIL=1 pmrun merger-session)" = 2 ] && grep -q 'cannot read PR' "$pm/out" && ok "a pr view that fails cannot attest" || bad "pr view failing"
[ "$(pmrun merger-session)" = 0 ] && grep -q "PR #1 head=$pm_head" "$pm/out" && ok "the check states which PR and which head commit it judged" || bad "head line"
( cd "$pm/repo" && PATH="$pm/bin:$PATH" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" --as merger-session >"$pm/out" 2>&1 ); r1=$?
( cd "$pm/repo" && PATH="$pm/bin:$PATH" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" >"$pm/out2" 2>&1 ); r2=$?
{ [ $r1 = 2 ] && grep -q usage "$pm/out" && [ $r2 = 2 ]; } && ok "no PR number is a usage error (exit 2)" || bad "missing PR number ($r1 $r2)"
( cd "$pm/repo" && PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_COMMENTS="$pm/comments.json" env -u KIT_GATE_REPO bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >"$pm/out" 2>&1 ); [ $? -eq 2 ] && grep -q KIT_GATE_REPO "$pm/out" && ok "no KIT_GATE_REPO cannot attest" || bad "missing KIT_GATE_REPO"
mkdir -p "$pm/lonely"; cp "$kr/kit/ops/premerge-check.sh" "$pm/lonely/"
( cd "$pm/repo" && PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$pm/lonely/premerge-check.sh" 1 --as merger-session >"$pm/out" 2>&1 ); [ $? -eq 2 ] && grep -q 'marker-parse.awk is missing' "$pm/out" && ok "a copy without marker-parse.awk beside it cannot attest" || bad "missing marker-parse.awk"
[ "$(PM_HEAD=notahex pmrun merger-session)" = 2 ] && grep -q 'Cannot attest' "$pm/out" && ok "an unreadable head cannot attest" || bad "unreadable head"
[ "$(PM_HEAD=abcdef1 pmrun merger-session)" = 2 ] && grep -q 'Cannot attest' "$pm/out" && ok "a head that is only seven hex characters is not a commit id and cannot attest" || bad "short head"
[ "$(PM_HEAD=$other pmrun merger-session)" = 1 ] && ok "an approval of the old head does not carry to a new head: the check reads no git history" || bad "approval of an old head"
[ "$(FAKE_COMMENTS_FAIL=1 pmrun merger-session)" = 2 ] && ok "a failing comments call cannot attest" || bad "comments call failing"
printf '{"comments": []}' > "$pm/comments.json"
[ "$(pmrun merger-session)" = 2 ] && ok "a comments reply without the reviews field cannot attest" || bad "reviews field missing"
pmjson "$ap"
[ "$(PM_PR='1;echo' pmrun merger-session)" = 2 ] && ok "a PR number that is not digits is refused before anything runs" || bad "PR number injection"
( cd "$pm/repo" && PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r KIT_SESSION_ID=someone-else bash "$kr/kit/ops/premerge-check.sh" 1 --as merger-session >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "--as that contradicts KIT_SESSION_ID cannot attest" || bad "--as versus KIT_SESSION_ID"
( cd "$pm/repo" && timeout 10 bash "$kr/kit/ops/premerge-check.sh" 1 --as >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "--as with no value prints usage and exits instead of looping" || bad "--as with no value"
asid_ok=1
for v in $'x\nreviewer-session' $'abc\n\x1b[31mRED\x1b[0m' $'merger-session\n' 'ab' 'merger session' 'révieweur'; do
  ( cd "$pm/repo" && PATH="$pm/bin:$PATH" FAKE_HEAD="$pm_head" FAKE_GATE_STATE=success FAKE_COMMENTS="$pm/comments.json" KIT_GATE_REPO=o/r bash "$kr/kit/ops/premerge-check.sh" 1 --as "$v" >"$pm/out" 2>&1 ); rc=$?
  { [ "$rc" -eq 2 ] && ! LC_ALL=C grep -q $'\x1b' "$pm/out"; } || { asid_ok=0; echo "  accepted --as: $(printf '%q' "$v")"; }
done
[ $asid_ok -eq 1 ] && ok "--as must be one plain ASCII id: a multi-line, escaped, spaced or non-ASCII value cannot attest" || bad "--as validation"
rm -rf "$pm"

echo "== status board"
sb="$(mktemp -d)"; mkdir -p "$sb/bin"
printf '#!/usr/bin/env bash\n[ "${FAKE_DOCKER_FAIL:-0}" = 1 ] && exit 1\nprintf "%%b" "${FAKE_DOCKER_PS:-}"\n' > "$sb/bin/docker"
printf '#!/usr/bin/env bash\ncase "$*" in *"${FAKE_HTTP_BAD:-@@none@@}"*) printf 500;; *) printf "%%s" "${FAKE_HTTP:-200}";; esac\n' > "$sb/bin/curl"; chmod +x "$sb/bin/docker" "$sb/bin/curl"
printf '#!/usr/bin/env bash\n[ "${FAKE_SYSTEMCTL_FAIL:-0}" = 1 ] && exit 1\nprintf "a.timer\\nb.timer\\nc.timer\\n"\n' > "$sb/bin/systemctl"; chmod +x "$sb/bin/systemctl"
sbcolor() {   # sbcolor VAR=value ...: prints gate_color for that configuration
  env PATH="$sb/bin:$PATH" KIT_STATUS_OUT="$sb/status.json" KIT_SHARED_TREE_PATH="$PWD" "$@" python3 kit/ops/status-board.py >/dev/null 2>&1
  python3 -c "import json; print(json.load(open('$sb/status.json'))['gate_color'])"
}
[ "$(sbcolor KIT_HEALTH_URLS= KIT_PROD_CONTAINERS=)" = unknown ] && ok "no configuration is unknown, not green" || bad "no configuration"
python3 -c "import json; json.load(open('$sb/status.json'))" && ok "the board is valid json" || bad "valid json"
[ "$(sbcolor KIT_PROD_CONTAINERS=api,db FAKE_DOCKER_PS=$'api\tUp 2 hours (healthy)\ndb\tUp 2 hours (healthy)\n')" = green ] && ok "every configured container healthy is green" || bad "all containers healthy"
[ "$(sbcolor KIT_PROD_CONTAINERS=api,db FAKE_DOCKER_PS=$'api\tUp 2 hours (healthy)\n')" = red ] && ok "a configured container that is not running is red (it used to be green)" || bad "container not running"
[ "$(sbcolor KIT_PROD_CONTAINERS=api,db FAKE_DOCKER_FAIL=1)" = unknown ] && ok "docker failing is unknown, never green" || bad "docker failing"
[ "$(sbcolor KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\tUp 2 hours (unhealthy)\n')" = red ] && ok "an unhealthy container is red" || bad "unhealthy container"
[ "$(sbcolor KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\tUp 3 hours\n')" = green ] && ok "a running container without a healthcheck counts as up" || bad "container without a healthcheck"
[ "$(sbcolor KIT_HEALTH_URLS=http://x FAKE_HTTP=500)" = red ] && ok "a failing health URL is red" || bad "failing health URL"
[ "$(sbcolor KIT_HEALTH_URLS=http://x FAKE_HTTP=200)" = green ] && ok "a passing health URL is green" || bad "passing health URL"
[ "$(sbcolor KIT_HEALTH_URLS=http://x FAKE_HTTP=200 KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=)" = red ] && ok "a passing check never hides a down container" || bad "mixed checks"
[ "$(sbcolor KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\tUp 3 hours (Paused)\n')" = red ] && ok "a paused container is red" || bad "paused container"
[ "$(sbcolor KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\tUp 5 seconds (health: starting)\n')" = red ] && ok "a container whose healthcheck is still starting is not green" || bad "starting container"
[ "$(sbcolor KIT_HEALTH_URLS=http://good.example,http://bad.example FAKE_HTTP_BAD=bad.example)" = red ] && ok "one failing URL among several is red" || bad "mixed health URLs"
[ "$(sbcolor KIT_HEALTH_URLS=http://good.example,http://also-good.example FAKE_HTTP_BAD=bad.example)" = green ] && ok "and all of them passing is green" || bad "all health URLs passing"
: > "$sb/empty.log"
[ "$(sbcolor KIT_FF_LOG="$sb/empty.log" KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\tUp 1 hour (healthy)\n')" = green ] && python3 -c "import json; d=json.load(open('$sb/status.json')); assert d['valid_for_seconds'] == 600 and d['shared_git'].get('ff_only_last') is None" && ok "an empty ff-only log does not break the board, and the board states how long it stays valid" || bad "empty ff-only log"
sbjson() {   # sbjson <python expression over d> VAR=value ...: runs the board, prints the expression
  local expr="$1"; shift
  rm -f "$sb/status.json"   # a stale file from an earlier run must never answer for this one
  env PATH="${SB_PATH:-$sb/bin:$PATH}" KIT_STATUS_OUT="$sb/status.json" KIT_SHARED_TREE_PATH="${SB_TREE:-$PWD}" "$@" "$(command -v python3)" kit/ops/status-board.py >/dev/null 2>&1
  python3 -c "import json,sys; d=json.load(open('$sb/status.json')); print(eval(sys.argv[1]))" "$expr"
}
[ "$(sbjson "d['timers']['count'] == 3 and not [e for e in d['section_errors'] if e.startswith('timers')]")" = True ] && ok "the timers count is the number of rows systemctl lists" || bad "timers count"
[ "$(sbjson "d['timers']['count'] is None and any(e.startswith('timers') for e in d['section_errors'])" FAKE_SYSTEMCTL_FAIL=1)" = True ] && ok "a systemctl that fails gives a null count and a section error, never a number" || bad "timers count when systemctl fails"
mkdir -p "$sb/nosysctl"; ln -s "$(command -v git)" "$sb/nosysctl/git"
[ "$(SB_PATH="$sb/nosysctl" sbjson "d['timers']['count'] is None and any(e.startswith('timers') for e in d['section_errors'])")" = True ] && ok "no systemctl on the machine is a null count, not 1" || bad "timers count with no systemctl"
mkdir -p "$sb/notarepo"
[ "$(SB_TREE="$sb/notarepo" sbjson "d['shared_git']['tracked_dirty'] is None and d['shared_git']['head'] is None and any(e.startswith('shared_git') for e in d['section_errors'])")" = True ] && ok "a shared checkout that git cannot read reports null fields and an error, not tracked_dirty false" || bad "unreadable shared checkout"
SB_OUT_DIR="$sb/deep/er"
out="$(env PATH="$sb/bin:$PATH" KIT_STATUS_OUT="$SB_OUT_DIR/board.json" KIT_SHARED_TREE_PATH="$PWD" "$(command -v python3)" kit/ops/status-board.py 2>&1)"; rc=$?
{ [ $rc = 0 ] && printf '%s' "$out" | grep -q 'wrote .*board.json gate_color=unknown' && [ -s "$SB_OUT_DIR/board.json" ]; } && ok "the board creates its output directory, says where it wrote, and exits 0" || bad "board output ($rc: $out)"
[ "$(sbjson "d['host']['hostname'] != '' and d['host']['uptime_seconds'] > 0 and len(d['host']['loadavg']) == 3 and d['host']['memory']['MemTotal'] > 0 and d['host']['disk_root']['size_bytes'] > 0 and d['host']['disk_root']['avail_bytes'] >= 0")" = True ] && ok "the host section reports hostname, uptime, load, memory and disk" || bad "host section"
[ "$(sbjson "d['containers'][0]['state'] == 'healthy' and d['containers'][0]['healthy'] is True" KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\\tUp 2 hours (healthy)\\n')" = True ] && ok "a healthy container is labelled healthy, not just up" || bad "healthy label"
[ "$(sbjson "d['containers'][0]['state'] == 'down' and d['containers'][0]['healthy'] is False and d['gate_color'] == 'red'" KIT_PROD_CONTAINERS=api FAKE_DOCKER_PS=$'api\\tRestarting (1) 3 seconds ago\\n')" = True ] && ok "a container that is restarting is down, not healthy" || bad "restarting container"
[ "$(SB_TREE="$sb/nowhere" sbjson "d['shared_git']['present'] is False")" = True ] && ok "a shared checkout that is not there is reported as absent" || bad "absent shared checkout"
sbrepo="$sb/repo"; git init -q -b main "$sbrepo"; echo a > "$sbrepo/f"; git -C "$sbrepo" add f; git -C "$sbrepo" -c user.name=t -c user.email=t@t commit -q -m a
[ "$(SB_TREE="$sbrepo" sbjson "d['shared_git']['present'] is True and d['shared_git']['branch'] == 'main' and len(d['shared_git']['head']) >= 7 and d['shared_git']['tracked_dirty'] is False and d['shared_git']['worktree_count'] == 1")" = True ] && ok "a readable shared checkout reports its branch, head, cleanliness and worktree count" || bad "shared checkout fields"
echo b >> "$sbrepo/f"
[ "$(SB_TREE="$sbrepo" sbjson "d['shared_git']['tracked_dirty'] is True")" = True ] && ok "and a changed tracked file makes tracked_dirty true" || bad "tracked_dirty"
mkdir -p "$sb/nocurl"; ln -s "$(command -v git)" "$sb/nocurl/git"; ln -s "$sb/bin/docker" "$sb/nocurl/docker"
[ "$(SB_PATH="$sb/nocurl" sbjson "d['gate_color'] == 'unknown' and any(e.startswith('health') for e in d['section_errors']) and d['health'] == []" KIT_HEALTH_URLS=http://x.example)" = True ] && ok "a curl that cannot run is a recorded section error and an unknown color, not a red service" || bad "no curl"
rm -rf "$sb"

echo "== backup health"
printf 'db/2026-09-28T05.dump\t100\t2026-09-28T06:00:00Z\ndb/2026-09-29T05.dump\t100\t2026-09-29T06:00:00Z\n' | KIT_NOW=2026-09-29T12:00:00Z python3 kit/ops/backup-health.py >/dev/null; [ $? -eq 0 ] && ok "fresh backup healthy" || bad "fresh backup healthy"
printf 'db/2026-09-20T05.dump\t100\t2026-09-20T06:00:00Z\n' | KIT_NOW=2026-09-29T12:00:00Z python3 kit/ops/backup-health.py >/dev/null 2>&1; [ $? -eq 1 ] && ok "stale backup is a finding" || bad "stale backup is a finding"
printf '' | KIT_NOW=2026-09-29T12:00:00Z python3 kit/ops/backup-health.py >/dev/null 2>&1; [ $? -eq 2 ] && ok "empty listing cannot attest" || bad "empty listing cannot attest"
printf 'garbage line\n' | KIT_NOW=2026-09-29T12:00:00Z python3 kit/ops/backup-health.py >/dev/null 2>&1; [ $? -eq 1 ] && ok "unparseable key is a finding, not a traceback" || bad "unparseable key is a finding"
bh() { python3 kit/ops/backup-health.py 2>&1; }   # reads a listing on stdin; the caller sets KIT_NOW and prints $? itself
week="$(for d in 22 23 24 25 26 27 28; do printf 'db/2026-09-%sT05.dump\t100\t2026-09-%sT06:00:00Z\n' "$d" "$d"; done)"
out="$(printf '%s\n' "$week" | KIT_NOW=2026-09-29T02:00:00Z bh)"; rc=$?
{ [ $rc = 0 ] && ! printf '%s' "$out" | grep -q WARN && printf '%s' "$out" | grep -q 'objects=7 newest=db/2026-09-28T05.dump age_h=20.0 size=100'; } && ok "a week of daily dumps is healthy and the summary names the newest object, its age and size" || bad "healthy week ($rc: $out)"
out="$(printf '%s\n' "$week" | KIT_NOW=2026-09-29T10:00:00Z bh)"; rc=$?
{ [ $rc = 0 ] && printf '%s' "$out" | grep -q 'WARN newest object .* (late)'; } && ok "an object past 80% of the age limit is a warning, not yet a failure" || bad "late warning ($rc: $out)"
out="$(printf '%s\n' "$week" | KIT_NOW=2026-09-29T02:00:00Z KIT_MAX_AGE_HOURS=10 bh)"; rc=$?
{ [ $rc = 1 ] && printf '%s' "$out" | grep -q 'FAIL newest object .* (max 10.0)'; } && ok "KIT_MAX_AGE_HOURS moves the limit" || bad "max age override ($rc: $out)"
out="$(printf '%s\n' "$week" | grep -v 2026-09-25 | KIT_NOW=2026-09-29T02:00:00Z bh)"; rc=$?
{ [ $rc = 0 ] && printf '%s' "$out" | grep -q 'WARN missing days in the last 7: 2026-09-25'; } && ok "a missing day is named in a warning" || bad "missing day ($rc: $out)"
out="$(printf 'db/2026-09-28T05.dump\t0\t2026-09-28T06:00:00Z\n' | KIT_NOW=2026-09-28T12:00:00Z bh)"; rc=$?
{ [ $rc = 1 ] && printf '%s' "$out" | grep -q 'FAIL newest object .* is 0 bytes'; } && ok "an empty newest object is a failure" || bad "empty object ($rc: $out)"
out="$(printf 'db/2026-09-28T05.dump\t100\t2026-09-28T06:00:00Z\nnot a listing line\n' | KIT_NOW=2026-09-28T12:00:00Z bh)"; rc=$?
{ [ $rc = 1 ] && printf '%s' "$out" | grep -q 'FAIL unparseable listing line 2' && printf '%s' "$out" | grep -q 'objects=1'; } && ok "one bad line is a finding and the good rows are still judged" || bad "mixed listing ($rc: $out)"

echo "== mutation check"
mt="$(mktemp -d)"; git init -q -b main "$mt"
printf '#!/usr/bin/env bash\n[ "$1" = a ] && echo A\n[ "$1" = b ] && echo B\n' > "$mt/s.sh"
printf '#!/usr/bin/env bash\n[ "$(bash s.sh a)" = A ] || exit 1\n' > "$mt/t.sh"; chmod +x "$mt/t.sh"
git -C "$mt" add -A; git -C "$mt" -c user.name=t -c user.email="$nr" commit -q -m base
out="$(cd "$mt" && python3 "$kr/kit/ops/mutate.py" --jobs 2 s.sh -- ./t.sh 2>&1)"
printf '%s\n' "$out" | grep -q 'SURVIVED s.sh:3  delete the line' && ok "the mutation check reports the line no test exercises as a survivor" || bad "mutation check: untested line"
printf '%s\n' "$out" | grep -q 'SURVIVED s.sh:2' && bad "the mutation check let a tested line survive" || ok "and kills every mutant of the line the test does exercise"
printf '%s\n' "$out" | grep -qE '^mutants: [0-9]+ valid, [0-9]+ killed, [0-9]+ survived' && ok "and prints one summary line with the counts" || bad "mutation check summary"
printf '#!/usr/bin/env bash\nexit 1\n' > "$mt/t.sh"; git -C "$mt" add -A; git -C "$mt" -c user.name=t -c user.email="$nr" commit -q -m failing
( cd "$mt" && python3 "$kr/kit/ops/mutate.py" s.sh -- ./t.sh >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "it refuses to run when the unmodified tests already fail: a mutation score means nothing then" || bad "mutation check on failing tests"
printf '#!/usr/bin/env bash\nn=0\nwhile [ "$n" -lt 2 ]; do\n  n=$((n+1))\ndone\necho A\n' > "$mt/s2.sh"; printf '#!/usr/bin/env bash\n[ "$(bash s2.sh)" = A ] || exit 1\n' > "$mt/t.sh"
git -C "$mt" add -A; git -C "$mt" -c user.name=t -c user.email="$nr" commit -q -m "a loop"
out="$(cd "$mt" && python3 "$kr/kit/ops/mutate.py" --jobs 2 --timeout 4 s2.sh -- ./t.sh 2>&1)"
printf '%s\n' "$out" | grep -qE '^mutants: [0-9]+ valid, [1-9][0-9]* killed' && ok "a mutant that loops forever is killed by the timeout, not waited for" || bad "mutation check with a hanging mutant"
sleep 1; ps -eo args | grep -q '[m]utant\.[^ ]*/s2\.sh' && bad "a hung mutant was left running" || ok "and nothing it started is left running"



mg="$(mktemp -d)"; git init -q -b main "$mg"
cat > "$mg/f.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -u
x=1
[ "$x" = 1 ] && echo "a = b && c"   # a comment with && and = inside
if [ "$x" -eq 1 ] || [ -z "$y" ]; then exit 1; fi
n=$(( x + 1 ))
echo done >&2
cat <<'PY'
if a == b and not c:
    z = 1
PY
cat <<EOF
x == y
EOF
# mutate:off
[ "$x" = 2 ] && exit 2
# mutate:on
echo "a \" && b" && echo c
echo 'it'"'"'s && ok' || echo d
y=2 # trailing comment && with || ops
echo \# not a comment && echo e
if true; then
  echo hi
fi
return_code=0
FIXTURE
cat > "$mg/f.py" <<'FIXTURE'
"""docstring with == and not"""
import sys
def f(a, b):
    """another docstring"""
    if a == b and not a:
        return 1
    c = a != b  # a comment with == in it
    sys.exit(2)
    return True
FIXTURE
cat > "$mg/f.awk" <<'FIXTURE'
BEGIN { live = 0 }
# comment with == in it
{ if ($1 == "a" && NR > 1) print "x == y" }
FIXTURE
git -C "$mg" add -A; git -C "$mg" -c user.name=t -c user.email="$nr" commit -q -m fixtures
cat > "$mg/golden.sh" <<'GOLDEN'
f.sh:3  delete the line    | x=1
f.sh:4  && -> ||    | [ "$x" = 1 ] && echo "a = b && c"   # a comment with && and = inside
f.sh:4  = -> !=    | [ "$x" = 1 ] && echo "a = b && c"   # a comment with && and = inside
f.sh:4  delete the line    | [ "$x" = 1 ] && echo "a = b && c"   # a comment with && and = inside
f.sh:5  || -> &&    | if [ "$x" -eq 1 ] || [ -z "$y" ]; then exit 1; fi
f.sh:5  exit 1 -> exit 0    | if [ "$x" -eq 1 ] || [ -z "$y" ]; then exit 1; fi
f.sh:5  -eq -> -ne    | if [ "$x" -eq 1 ] || [ -z "$y" ]; then exit 1; fi
f.sh:5  -z -> -n    | if [ "$x" -eq 1 ] || [ -z "$y" ]; then exit 1; fi
f.sh:6  delete the line    | n=$(( x + 1 ))
f.sh:7  delete the line (message)    | echo done >&2
f.sh:18  && -> ||    | echo "a \" && b" && echo c
f.sh:18  delete the line    | echo "a \" && b" && echo c
f.sh:19  || -> &&    | echo 'it'"'"'s && ok' || echo d
f.sh:19  delete the line    | echo 'it'"'"'s && ok' || echo d
f.sh:20  delete the line    | y=2 # trailing comment && with || ops
f.sh:21  && -> ||    | echo \# not a comment && echo e
f.sh:21  delete the line    | echo \# not a comment && echo e
f.sh:25  delete the line    | return_code=0
f.sh:9  == -> != (python)    | if a == b and not c:
f.sh:9  and -> or (python)    | if a == b and not c:
f.sh:9  not -> (removed) (python)    | if a == b and not c:
21 mutants
GOLDEN
cat > "$mg/golden.py" <<'GOLDEN'
f.py:5  == -> !=    | if a == b and not a:
f.py:5  and -> or    | if a == b and not a:
f.py:5  not -> (removed)    | if a == b and not a:
f.py:6  1 -> 0    | return 1
f.py:7  != -> ==    | c = a != b  # a comment with == in it
f.py:8  2 -> 0    | sys.exit(2)
f.py:9  True -> False    | return True
f.py:7  delete the statement    | c = a != b  # a comment with == in it
f.py:8  delete the statement    | sys.exit(2)
f.py:9  delete the statement    | return True
10 mutants
GOLDEN
cat > "$mg/golden.awk" <<'GOLDEN'
f.awk:1  delete the line    | BEGIN { live = 0 }
f.awk:3  == -> !=    | { if ($1 == "a" && NR > 1) print "x == y" }
f.awk:3  && -> ||    | { if ($1 == "a" && NR > 1) print "x == y" }
f.awk:3  > -> <=    | { if ($1 == "a" && NR > 1) print "x == y" }
4 mutants
GOLDEN
for f in sh py awk; do
  ( cd "$mg" && python3 "$kr/kit/ops/mutate.py" --list "f.$f" -- true > "$mg/list.$f" 2>&1 )
  diff -u "$mg/golden.$f" "$mg/list.$f" > "$mg/diff.$f" 2>&1 && ok "the mutants of a .$f file are exactly the expected ones: code only, never strings, comments, docstrings, skipped regions or heredoc terminators" || { cat "$mg/diff.$f"; bad "mutant list for .$f"; }
done
mw="$(mktemp -d)"; git init -q -b main "$mw"
printf '#!/usr/bin/env bash\n[ "$1" = a ] && echo A\n' > "$mw/s.sh"; chmod +x "$mw/s.sh"; printf 'x\n' > "$mw/gone.txt"; printf '#!/usr/bin/env bash\nexit 1\n' > "$mw/t.sh"; chmod +x "$mw/t.sh"
git -C "$mw" add -A; git -C "$mw" -c user.name=t -c user.email="$nr" commit -q -m base
# the WORKING TREE is what gets tested: an uncommitted t.sh, a tracked file deleted, the executable bit, the sections, fail-fast, a scratch dir outside the copy, a clone with history
cat > "$mw/t.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
[ "$(./s.sh a)" = A ] || exit 1
[ ! -e gone.txt ] || exit 1
[ "${KIT_TEST_SECTIONS:-}" = alpha,beta ] || exit 1
[ "${KIT_TEST_FAILFAST:-}" = 1 ] || exit 1
case "$TMPDIR" in "$PWD"*) exit 1 ;; esac
git rev-parse --verify -q HEAD >/dev/null || exit 1
TESTSCRIPT
rm -f "$mw/gone.txt"
printf '#!/usr/bin/env bash\n[ "$1" = a ] && echo A\n[ "$1" = b ] && echo B\n' > "$mw/s.sh"
out="$( cd "$mw" && python3 "$kr/kit/ops/mutate.py" --jobs 2 --report "$mw.report" s.sh:alpha,beta -- ./t.sh 2>&1 )"; rc=$?
{ [ $rc = 0 ] && printf '%s\n' "$out" | grep -q 'baseline: running the unmodified tests, sections alpha,beta' && grep -q '^SURVIVED s.sh:3  delete the line' "$mw.report" && head -1 "$mw.report" | grep -qE '^mutants: [0-9]+ valid, [1-9][0-9]* killed, [1-9][0-9]* survived'; } && ok "it tests the working tree in a clone with history: uncommitted edits, deleted files, modes, the section list, fail-fast and an outside scratch dir all reach the tests, and an untested line is reported as a survivor only because they do" || bad "harness environment ($rc: $out)"
out="$( cd "$mw" && python3 "$kr/kit/ops/mutate.py" --jobs 2 --sample 1 --seed 3 s.sh:alpha,beta -- ./t.sh 2>&1 )"
{ printf '%s\n' "$out" | grep -q 'sampling 1 of [0-9]* valid mutants (seed 3)' && printf '%s\n' "$out" | grep -qE '^mutants: 1 valid'; } && ok "--sample and --seed pick a subset and say so" || bad "sampling"
( cd "$mw" && python3 "$kr/kit/ops/mutate.py" s.sh >/dev/null 2>"$mw.err" ); r1=$?; ( cd "$mw" && python3 "$kr/kit/ops/mutate.py" s.sh -- >/dev/null 2>&1 ); r2=$?
{ [ $r1 -ne 0 ] && grep -q usage "$mw.err" && [ $r2 -ne 0 ]; } && ok "without a test command after -- it prints usage and does nothing" || bad "mutate usage ($r1 $r2)"
echo "== result"
echo; [ $fails -eq 0 ] && { echo "RESULT: all passed"; exit 0; } || { echo "RESULT: $fails failed"; exit 1; }
