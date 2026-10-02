#!/usr/bin/env bash
# Leak gate. Exit 0 clean, 1 hit, 2 cannot attest.
#
#   ./scan.sh              scan the working tree
#   ./scan.sh --history    scan every commit reachable from any ref
#
# A repo that goes public publishes ALL of its history, so a clean tree proves
# nothing about publishability. Run both, in this order, and chain the publish
# on the exit codes with && (never ;):
#     ./scan.sh && ./scan.sh --history && <publish>
# If the history is not clean, do not flip visibility: build a snapshot with
# ./export-public.sh and publish that.
#
# This is a SAFER way to publish, not a proof. It checks what a list of patterns can see, and
# the limits are real (see LIMITS below).
#
# WHAT IT READS. Every file's content, as text, against every pattern. Every file NAME; in
# history also commit authors, committers and messages, every other commit header, tag names,
# taggers and tag messages, ref names, and every file name any commit ever had. And structure no
# pattern can see, each of which REFUSES the scan because a text scan cannot read it: binary
# files (NUL bytes, UTF-16, gzip, images), files that are not valid UTF-8, invisible and
# direction-changing or control characters, chosen by Unicode property (they can split an identifier
# so no pattern matches), file names that are not valid UTF-8 or hold a newline, carriage return or tab, symbolic
# links, submodules, a sparse checkout, a .gitattributes that changes how git stores, shows or
# exports files, and in history signed commits and tags (a signature embeds the signer's key
# identity), commit headers other than tree, parent, author and committer, replace refs, and refs that
# point at something that is not a commit. KIT_ALLOW_BINARY=1 allows binary and non-UTF-8 files, and skips the
# invisible-character check on file contents (binary data holds every byte sequence),
# once a human has inspected them.
#
# PATTERNS. POSIX ERE (grep -E), one per line, case-insensitive, a line starting with # is a
# comment. NOT PCRE: a backslash before a letter other than b, B, w, W, s, S is rejected (grep
# reads \d, \x67 or \t as a plain letter, so the pattern would silently check nothing), and so
# is a pattern that matches an empty line. They come from:
#   denylist.generic.txt   shipped here: generic shapes only (emails, uuids, addresses, private
#                          IP ranges, key and token shapes). Safe to publish.
#   $KIT_DENYLIST_LOCAL    YOUR identifiers: private repo names, hostnames, buckets, people,
#                          vendors under embargo. Default ~/.config/battleship-kit/denylist.txt.
#                          NEVER commit it. A denylist that is itself in the tree publishes
#                          exactly the names it exists to protect. This kit once did that,
#                          privately, in every commit.
# A missing or empty local list is exit 2 (cannot attest): a publish gate must not silently
# check less. KIT_ALLOW_GENERIC_ONLY=1 scans with the generic patterns alone, with a warning.
# KIT_REQUIRE_LOCAL=1 overrides that. A list with a byte-order mark, NUL bytes, invalid UTF-8,
# inline comments or an unusual line separator is refused rather than half-read.
#
# Output never prints a local pattern or the matched text, only file:line (or commit:file:line).
# A path that itself matches a pattern is withheld, and so is every hit in a file name or in
# history metadata, so the log of a failing scan cannot leak what it protects.
#
# LIMITS. It does not decode: base64, rot13, percent-encoding and HTML entities of a listed name
# pass. It does not normalise Unicode: a pattern written in one composed form (NFC) misses the same
# text in the decomposed form (NFD) that some systems produce. It reads lines: a name wrapped across two lines, or split by a separator you did not list,
# passes. Look-alike letters (a Cyrillic "a") pass. It knows only the shapes and names on its
# lists, so a public IP address, a domain or a person you never listed passes. Reflogs and objects
# no ref reaches are not read, because they are not published. It must sit at the repository root.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
# Read the repository this script sits in, not whatever the caller's environment points at, and
# read the objects a clone receives (refs/replace rewrites what a local git shows; grafts are refused below).
while read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars 2>/dev/null)
export GIT_NO_REPLACE_OBJECTS=1
# One UTF-8 locale for every verdict, whatever the caller's: case folding and byte handling must
# not vary. The probe proves the locale is real: in a UTF-8 locale an invalid byte is not "."
utf8=0
for loc in C.UTF-8 en_US.UTF-8 en_GB.UTF-8; do
  if ! printf '\351\n' | LC_ALL=$loc grep -qax -e '.*' 2>/dev/null; then export LC_ALL=$loc; utf8=1; break; fi
done
[[ $utf8 -eq 1 ]] || { echo "scan: no UTF-8 locale is available on this system; cannot attest" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }   # no coreutils timeout: run without one

mode=tree
case "${1:-}" in
  "") ;;
  --history) mode=history ;;
  *) echo "usage: scan.sh [--history]" >&2; exit 2 ;;
esac
generic=denylist.generic.txt
localf="${KIT_DENYLIST_LOCAL:-$HOME/.config/battleship-kit/denylist.txt}"
tmp="$(mktemp -d 2>/dev/null)" && [[ -n "$tmp" && -d "$tmp" ]] || { echo "scan: cannot create a temporary directory (is TMPDIR usable?); cannot attest" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

[[ -f "$generic" ]] || { echo "scan: $generic is missing; cannot attest" >&2; exit 2; }
have_local=0
if [[ -f "$localf" ]]; then
  have_local=1
elif [[ "${KIT_ALLOW_GENERIC_ONLY:-0}" == 1 && "${KIT_REQUIRE_LOCAL:-0}" != 1 ]]; then
  echo "scan: WARNING no local denylist; scanning with the generic patterns only (KIT_ALLOW_GENERIC_ONLY=1). Your own identifiers are NOT being checked." >&2
else
  echo "scan: no local denylist at the configured path; cannot attest. Create one (see PUBLISHING.md) or set KIT_ALLOW_GENERIC_ONLY=1 to scan with the generic patterns alone." >&2; exit 2
fi
in_repo=0; git rev-parse --git-dir >/dev/null 2>&1 && in_repo=1
if [[ $mode == history && $in_repo -eq 0 ]]; then
  echo "scan: --history needs a git repository; cannot attest" >&2; exit 2
fi
if [[ $in_repo -eq 1 && "$(pwd -P)" != "$(git rev-parse --show-toplevel)" ]]; then
  echo "scan: this script must sit at the repository root; run from a subdirectory it would cover only that directory. Cannot attest." >&2; exit 2
fi
if [[ $mode == history && "$(git rev-parse --is-shallow-repository 2>/dev/null)" != false ]]; then
  echo "scan: this clone is shallow (or git cannot say); the history that ships is not here. Cannot attest." >&2; exit 2
fi
if [[ $mode == history && -e "$(git rev-parse --git-path info/grafts 2>/dev/null)" ]]; then
  echo "scan: this repository has a grafts file, which rewrites history locally but not in a clone. Cannot attest." >&2; exit 2
fi

# A local denylist that git tracks is the leak this script exists to prevent.
if [[ $in_repo -eq 1 && -n "$(git ls-files -- 'denylist.local*' '*.local.txt')" ]]; then
  echo "scan: a local denylist is tracked by git; untrack it and purge it from history" >&2; exit 1
fi

# A list that cannot be read as written would silently check less, so refuse it.
lint_list() {   # lint_list <file>: exit 1 and print the reasons if the list cannot be trusted
  python3 - "$1" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
problems = []
if b.startswith(b'\xef\xbb\xbf'): problems.append('byte-order mark')
if b'\x00' in b: problems.append('NUL bytes (UTF-16?)')
try: t = b.decode('utf-8')
except UnicodeDecodeError: problems.append('not valid UTF-8'); t = b.decode('utf-8', 'replace')
if any(c in t.replace('\r\n', '\n') for c in '\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029'):
    problems.append('a line separator other than newline or CRLF (grep and this check would split the lines differently)')
for n, line in enumerate(t.splitlines(), 1):
    s = line.rstrip('\r')
    if not s.strip() or s.lstrip().startswith('#'): continue
    if ' #' in s: problems.append('line %d has an inline comment (put comments on their own line)' % n)
    inb = False; i = 0
    while i < len(s):   # an unescaped $ outside a bracket expression must be written [[:cntrl:]]*$: a line ending in CR would otherwise hide a match
        c = s[i]
        if c == '\\': i += 2; continue
        if not inb and c == '[':
            inb = True; i += 1
            if s[i:i + 1] == '^': i += 1
            if s[i:i + 1] == ']': i += 1
            continue
        if inb and s[i:i + 2] == '[:':
            j = s.find(':]', i + 2); i = j + 2 if j >= 0 else len(s); continue
        if inb and c == ']': inb = False
        elif not inb and c == '$' and not s[:i].endswith('[[:cntrl:]]*'):
            problems.append('line %d ends a pattern with $, which cannot match a line that ends in a carriage return (write [[:cntrl:]]*$ instead)' % n); break
        i += 1
    i = 0
    while i < len(s):
        if s[i] == '\\':
            if i + 1 < len(s) and s[i + 1].isascii() and s[i + 1].isalpha() and s[i + 1] not in 'bBwWsS':
                problems.append('line %d has \\%s, which grep -E reads as a plain letter, so the pattern checks something else (write the literal character; a literal backslash is \\\\)' % (n, s[i + 1]))
                break
            i += 2
        else: i += 1
print('; '.join(problems)); sys.exit(1 if problems else 0)
PY
}
reasons="$(lint_list "$generic")" || { echo "scan: the shipped list cannot be trusted: $reasons" >&2; exit 2; }
if [[ $have_local -eq 1 ]]; then
  reasons="$(lint_list "$localf")" || { echo "scan: the local list cannot be trusted: $reasons" >&2; exit 2; }
fi
clean_list() { grep -avE '^[[:space:]]*(#|$)' "$1" | sed -E 's/\r$//; s/^[[:space:]]+//; s/[[:space:]]+$//'; }
clean_list "$generic" > "$tmp/generic.pats"
if [[ $have_local -eq 1 ]]; then clean_list "$localf" > "$tmp/local.pats"; else : > "$tmp/local.pats"; fi
cat "$tmp/generic.pats" "$tmp/local.pats" > "$tmp/all.pats"
ng="$(wc -l < "$tmp/generic.pats" | tr -d ' ')"; nl="$(wc -l < "$tmp/local.pats" | tr -d ' ')"
if [[ $have_local -eq 1 && $nl -eq 0 ]]; then
  if [[ "${KIT_ALLOW_GENERIC_ONLY:-0}" == 1 && "${KIT_REQUIRE_LOCAL:-0}" != 1 ]]; then
    echo "scan: WARNING the local list has no active patterns (KIT_ALLOW_GENERIC_ONLY=1). Your own identifiers are NOT being checked." >&2
  else
    echo "scan: the local list has no active patterns; cannot attest" >&2; exit 2
  fi
fi

hits=0; bad=0; struct=0
: > "$tmp/empty"
# A pattern grep cannot compile makes grep exit 2 with no output, which reads as "no hit".
# That is fail-open, so every pattern is validated with BOTH engines this script uses (grep -E for
# the tree, git grep -E for history) and an unusable one blocks attestation. A pattern that matches
# an empty line (x*, ^) would hit everything and drown the real hits, so it is unusable too.
why=""
valid_pat() {
  why="not usable as a POSIX ERE"
  printf '' | grep -E -e "$1" >/dev/null 2>&1; [[ $? -ne 2 ]] || return 1
  git -C "$tmp" grep --no-index -qE -e "$1" -- empty >/dev/null 2>&1; [[ $? -le 1 ]] || return 1
  if printf '\n' | grep -Eq -e "$1" 2>/dev/null; then why="it matches an empty line, so it would hit every file"; return 1; fi
  return 0
}

refuse() { struct=$((struct+1)); echo "REFUSE $1"; }
# One search over every batch of revisions; prints the matching lines. A failed search exits the
# whole script with 2, so call it with its output redirected to a file, never inside $(...) or a
# pipeline: there the exit would only leave the subshell and the failure would read as "no hits".
hist_search() {   # hist_search <git grep options...> [-- <pathspec>...]: the revisions go between the two
  local opts=() paths=() seen=0 a b o rc
  for a in "$@"; do
    if [[ $a == -- && $seen -eq 0 ]]; then seen=1; elif [[ $seen -eq 1 ]]; then paths+=("$a"); else opts+=("$a"); fi
  done
  for b in "$tmp"/revs.*; do
    # shellcheck disable=SC2046  # the batch is a list of hex revisions: word splitting is the point
    o="$(timeout 120 git grep "${opts[@]}" $(cat "$b") ${paths[@]+-- "${paths[@]}"} 2>/dev/null)"; rc=$?
    if [[ $rc -ge 2 ]]; then echo "scan: a history search failed or timed out, so its result cannot be trusted; cannot attest" >&2; exit 2; fi
    [[ -z $o ]] || printf '%s\n' "$o"
  done
}
# Characters that are invisible or change how text is laid out, as literal characters in a UTF-8 pattern
# (bracket expressions of single characters, no ranges, so no locale can reorder them). They are chosen by Unicode PROPERTY, not
# from a list somebody remembered: every format character (Cf: zero-width, joiners, direction marks, soft
# hyphen, byte-order mark, tags), every control character except tab, newline and carriage return (Cc, so
# ESC and the C1 set too), the line and paragraph separators (Zl, Zp), the fillers and the combining grapheme
# joiner, the Mongolian selectors; and the variation selectors when they follow an ASCII letter or digit (an
# emoji may carry one, an identifier may not). Built from code points so this file holds none of them itself.
invis="$(python3 - <<'PY'
import sys, unicodedata
cps = {c for c in range(1, 0x110000) if unicodedata.category(chr(c)) in ("Cf", "Cc", "Zl", "Zp") and chr(c) not in "\t\n\r"}
cps |= {0x34F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0} | set(range(0x180B, 0x1810))
vs = [chr(c) for c in list(range(0xFE00, 0xFE10)) + list(range(0xE0100, 0xE01F0))]
# two bracket expressions of single characters (no ranges, no locale ordering); far cheaper for grep than 500 alternatives
sys.stdout.buffer.write(("[" + "".join(chr(c) for c in sorted(cps)) + "]|[0-9A-Za-z][" + "".join(vs) + "]").encode("utf-8"))
PY
)"
[[ -n $invis ]] || { echo "scan: could not build the invisible-character pattern; cannot attest" >&2; exit 2; }
if [[ $mode == tree ]]; then
  n="$(find . -path ./.git -prune -o -type l -print | wc -l)"
  [[ $n -eq 0 ]] || refuse "the tree holds $n symbolic link(s); a link's target is never scanned. Remove them."
  if [[ $in_repo -eq 1 ]]; then
    n="$(git ls-files -s | awk '$1=="160000"' | wc -l)"
    [[ $n -eq 0 ]] || refuse "the tree holds $n submodule(s); their content is not part of this repo and is not scanned."
    n="$(git ls-files -t | awk '$1=="S"' | wc -l)"
    [[ $n -eq 0 ]] || refuse "the work tree is sparse: $n tracked file(s) are not checked out and were not scanned. Run git sparse-checkout disable."
  fi
  if [[ "${KIT_ALLOW_BINARY:-0}" != 1 ]]; then
    n=0; while IFS= read -r -d '' f; do [[ -s "$f" ]] && n=$((n+1)); done < <(grep -rILZ -e '' --exclude-dir=.git . 2>/dev/null)
    [[ $n -eq 0 ]] || refuse "the tree holds $n binary file(s); a text scan cannot read them. Remove them, or set KIT_ALLOW_BINARY=1 once a human has inspected them. Files .gitignore hides are scanned too: delete build output such as __pycache__."
    n="$(grep -rlaxv --exclude-dir=.git -e '.*' . 2>/dev/null | wc -l)"
    [[ $n -eq 0 ]] || refuse "the tree holds $n file(s) that are not valid UTF-8 (latin-1 text, a compressed stream); a pattern cannot read them. Convert or remove them, or set KIT_ALLOW_BINARY=1 once a human has inspected them."
  fi
  if [[ "${KIT_ALLOW_BINARY:-0}" != 1 ]]; then   # binary data contains every byte sequence; text files are what this guards
    n="$(grep -rlaE --exclude-dir=.git -e "$invis" . 2>/dev/null | wc -l)"
    [[ $n -eq 0 ]] || refuse "the tree holds $n file(s) with invisible, control or direction-changing characters (zero-width, soft hyphen, bidi, byte-order mark, escape); they can split an identifier so no pattern matches. Remove them."
  fi
  n="$(find . -path ./.git -prune -o -name .gitattributes -type f -print0 | xargs -0 -r grep -aEc 'export-ignore|export-subst|-diff|-text|binary|filter=|ident' 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
  [[ $n -eq 0 ]] || refuse "a .gitattributes changes how git stores, shows or exports files ($n rule(s)); that can hide or rewrite text. Remove it."
else
  git rev-list --all > "$tmp/revs" || { echo "scan: git could not list the commits; cannot attest" >&2; exit 2; }
  [[ -s "$tmp/revs" ]] || { echo "scan: the repository has no commits; nothing to attest" >&2; exit 2; }
  split -l 100 "$tmp/revs" "$tmp/revs."
  n="$(git log --all --raw --no-renames --format= | awk '$1==":120000" || $2=="120000"' | wc -l)"
  [[ $n -eq 0 ]] || refuse "history holds $n symbolic link change(s); a link's target is never scanned."
  n="$(git log --all --raw --no-renames --format= | awk '$1==":160000" || $2=="160000"' | wc -l)"
  [[ $n -eq 0 ]] || refuse "history holds $n submodule change(s)."
  if [[ "${KIT_ALLOW_BINARY:-0}" != 1 ]]; then
    n="$(git log --all --numstat --format= | awk -F'\t' '$1=="-" && $2=="-"' | wc -l)"
    [[ $n -eq 0 ]] || refuse "history holds $n binary file change(s); a text scan cannot read them."
    hist_search -a -v -c -e '^.*$' > "$tmp/hs"; n="$(wc -l < "$tmp/hs" | tr -d ' ')"
    [[ $n -eq 0 ]] || refuse "history holds $n file version(s) that are not valid UTF-8; a pattern cannot read them."
  fi
  if [[ "${KIT_ALLOW_BINARY:-0}" != 1 ]]; then
    hist_search -a -E -c -e "$invis" > "$tmp/hs"; n="$(wc -l < "$tmp/hs" | tr -d ' ')"
    [[ $n -eq 0 ]] || refuse "history holds $n file version(s) with invisible, control or direction-changing characters; they can split an identifier so no pattern matches."
  fi
  hist_search -a -E -c -e 'export-ignore|export-subst|-diff|-text|binary|filter=|ident' -- '.gitattributes' '*/.gitattributes' > "$tmp/hs"; n="$(wc -l < "$tmp/hs" | tr -d ' ')"
  [[ $n -eq 0 ]] || refuse "history holds a .gitattributes that changes how git stores, shows or exports files."
fi

# Content is not everything git publishes. File names always ship; in history so do commit
# authors, messages, every other header, tags, ref names, and every file name any commit ever had.
# Those are checked too, as one list of lines. Only the DOMAIN of a well-known noreply address is
# removed, never its local part: the local part is where a handle or an identifier would be.
# Hits there print no location.
extra_what="a file name"
if [[ $mode == tree ]]; then
  # A name with a newline is several lines to every tool below: its second line can look like a path
  # that is exempt from a pattern. Refuse it rather than parse it.
  if ! find . -path ./.git -prune -o -print0 | python3 -c 'import re, sys; sys.exit(1 if any(re.search(rb"[\n\r\t]", n) for n in sys.stdin.buffer.read().split(b"\0")) else 0)'; then
    refuse "a file or directory name holds a newline, carriage return or tab; every tool that reads names line by line would read it as several."
  fi
  find . -path ./.git -prune -o -type f -print | sed 's|^\./||' > "$tmp/extra"
else
  extra_what="history metadata (commit authors, headers and messages, tags, refs, or file names)"
  feed() {   # feed <revs-file> <out-file>: prints "ISSUE <kind> <count>" lines; exits 2 if git cannot be read
    python3 - "$1" "$2" <<'PY'
import re, subprocess, sys
revs_path, out_path = sys.argv[1], sys.argv[2]
def git(*args, inp=None):
    p = subprocess.run(["git", *args], input=inp, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.stderr.write("git %s failed\n" % " ".join(args)); sys.exit(2)
    return p.stdout
revs = open(revs_path).read().split()
feed = set()
issues = {"signed commits": 0, "merge of a signed tag": 0, "commits with headers other than tree, parent, author and committer": 0,
          "signed tags": 0, "refs that point at something that is not a commit": 0,
          "replace refs (a mirror clone carries the objects they name, which no commit reaches)": 0,
          "file names that hold a newline, carriage return or tab": 0}
ident = re.compile(rb"^(author|committer) (.*) [0-9]+ [+-][0-9]{4}$")
def add_lines(b):
    for ln in b.split(b"\n"):
        if ln.strip(): feed.add(ln)
def read_headers(head, tag=False):
    """Return (signed, merged_tag, odd) and feed everything a person could read."""
    signed = merged = odd = False; skip = False
    for ln in head.split(b"\n"):
        if ln.startswith(b" "):
            if not skip: feed.add(ln)
            continue
        skip = False
        name = ln.split(b" ", 1)[0]
        if name in ((b"object", b"type") if tag else (b"tree", b"parent")): continue
        if name in (b"gpgsig", b"gpgsig-sha256"): signed = True; skip = True; continue
        if name == b"mergetag": merged = True; skip = True; continue
        m = ident.match(ln) if name in (b"author", b"committer") else None
        if m: feed.add(m.group(2)); continue
        if name == b"tagger":
            feed.add(re.sub(rb"^tagger (.*) [0-9]+ [+-][0-9]{4}$", rb"\1", ln)); continue
        if name == b"tag" and tag: feed.add(ln); continue
        if name not in (b"author", b"committer"): odd = True
        feed.add(ln)
    return signed, merged, odd
inp = b"".join(r.encode() + b"\n" for r in revs)
cf = subprocess.run(["git", "cat-file", "--batch"], input=inp, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if cf.returncode != 0:
    sys.stderr.write("git cat-file failed\n"); sys.exit(2)
data = cf.stdout
pos = 0; trees = set()
for r in revs:
    nl = data.find(b"\n", pos)
    hdr = data[pos:nl].split() if nl >= 0 else []
    if len(hdr) != 3 or hdr[1] != b"commit":
        sys.stderr.write("object %s is not a readable commit\n" % r); sys.exit(2)
    size = int(hdr[2]); raw = data[nl + 1:nl + 1 + size]; pos = nl + 1 + size + 1
    if len(raw) != size or data[pos - 1:pos] != b"\n":   # a record cut short must never read as a clean message
        sys.stderr.write("object %s was read short\n" % r); sys.exit(2)
    head, _, msg = raw.partition(b"\n\n")
    signed, merged, odd = read_headers(head)
    issues["signed commits"] += signed; issues["merge of a signed tag"] += merged
    issues["commits with headers other than tree, parent, author and committer"] += odd
    add_lines(msg)
    m = re.match(rb"tree ([0-9a-f]+)", head)
    if m: trees.add(m.group(1).decode())
for t in sorted(trees):
    for name in git("ls-tree", "-r", "-z", "--name-only", t).split(b"\0"):
        if re.search(rb"[\n\r\t]", name): issues["file names that hold a newline, carriage return or tab"] += 1
        if name: feed.add(name)
for line in git("for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)").split(b"\n"):
    if not line: continue
    ref, sha, typ = line.split(b"\0")
    feed.add(ref)
    depth = 0
    while typ == b"tag" and depth < 20:
        raw = git("cat-file", "tag", sha.decode()); depth += 1
        head, _, msg = raw.partition(b"\n\n")
        read_headers(head, tag=True)
        for marker in (b"-----BEGIN PGP SIGNATURE-----", b"-----BEGIN SSH SIGNATURE-----"):
            if marker in msg: issues["signed tags"] += 1; msg = msg.split(marker, 1)[0]
        add_lines(msg)
        m = re.search(rb"^object ([0-9a-f]+)\ntype (\w+)", head, re.M)
        if not m: typ = b"unreadable"; break
        sha, typ = m.group(1), m.group(2)
    if ref.startswith(b"refs/replace/"): issues["replace refs (a mirror clone carries the objects they name, which no commit reaches)"] += 1
    elif typ != b"commit": issues["refs that point at something that is not a commit"] += 1
with open(out_path, "wb") as f: f.write(b"\n".join(sorted(feed)) + b"\n")
for k, v in issues.items():
    if v: print("%d\t%s" % (v, k))
PY
  }
  issues="$(feed "$tmp/revs" "$tmp/extra.raw")" || { echo "scan: git objects could not be read; cannot attest" >&2; exit 2; }
  while IFS=$'\t' read -r cnt what; do
    [[ -n ${cnt:-} ]] && refuse "history holds $cnt of: $what. A text scan cannot read them."
  done <<<"$issues"
  sed -E 's/@users\.noreply\.github\.com//g; s/(noreply)@(anthropic|github)\.com/\1/g' "$tmp/extra.raw" > "$tmp/extra"
fi
python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' < "$tmp/extra" 2>/dev/null || refuse "a file name or history metadata line is not valid UTF-8; a pattern cannot read it, and a reader would see replacement characters."
n="$(grep -caE -e "$invis" "$tmp/extra" 2>/dev/null)"
[[ ${n:-0} -eq 0 ]] || refuse "a file name or history metadata line holds invisible or direction-changing characters; they can split an identifier so no pattern matches."

scan_content() {   # scan_content <generic|local> <pattern>: prints path:line (or rev:path:line); returns 2 if the engine failed
  local kind="$1" pat="$2" o b rc out="" gx=()
  [[ $kind == generic ]] && gx=(":(exclude)$generic")   # history: only the root copy of the shipped list is exempt from the generic patterns
  if [[ $mode == tree ]]; then
    # NUL after the path, so a colon in a path cannot confuse the parse. Only the ROOT copy of the shipped list
    # is exempt from the generic patterns (its own pattern text matches them), and only root-level local lists
    # are skipped: a file of the same name anywhere else is scanned like any other.
    local soh=$'\001'
    grep -raniEZ --exclude-dir=.git -e "$pat" . > "$tmp/hits.raw" 2>/dev/null; rc=$?
    [[ $rc -ge 2 ]] && return 2
    o="$(tr '\0' "$soh" < "$tmp/hits.raw" | grep -av "^\./denylist\.local[^$soh/]*$soh" || true)"
    if [[ $kind == generic ]]; then o="$(printf '%s\n' "$o" | grep -av "^\./$(printf '%s' "$generic" | sed 's/\./\\./g')$soh" || true)"; fi
    printf '%s\n' "$o" | sed -n "s/^\([^$soh]*\)$soh\([0-9][0-9]*\):.*/\1:\2/p" | sort -u
  else
    for b in "$tmp"/revs.*; do
      # shellcheck disable=SC2046
      o="$(timeout 120 git grep -anE -i -e "$pat" $(cat "$b") -- . ${gx[@]+"${gx[@]}"} 2>/dev/null)"; rc=$?
      [[ $rc -ge 2 ]] && return 2
      out="$out$o"$'\n'
    done
    printf '%s' "$out" | cut -d: -f1-3 | sed 's/^\([0-9a-f]\{8\}\)[0-9a-f]*:/\1:/' | sort -u
  fi
}
# A location names a file. If the file's own name matches a pattern, printing it would repeat the
# identifier in the log, so the name is withheld.
show_locations() {   # reads path:line (or rev:path:line) on stdin
  local loc p n pre rc
  while IFS= read -r loc; do
    [[ -n $loc ]] || continue
    n="${loc##*:}"; p="${loc%:*}"; pre=""
    if [[ $mode == history ]]; then pre="${p%%:*}:"; p="${p#*:}"; fi
    printf '%s\n' "$p" | grep -aiqE -f "$tmp/all.pats" 2>/dev/null; rc=$?
    if [[ $rc -eq 1 ]]; then printf '%s\n' "$loc"; else printf '%s<path withheld>:%s\n' "$pre" "$n"; fi
  done
}
# The shipped generic list is exempt from the GENERIC patterns only (its own comments and
# pattern text match them). Local patterns still scan it, so a real identifier written
# into the shipped list is caught.
scan_one() {   # scan_one <generic|local> <label> <pattern>
  local kind="$1" label="$2" pat="$3" out total rc
  if ! valid_pat "$pat"; then bad=$((bad+1)); echo "UNUSABLE $label: $why, so it was NOT checked"; return 0; fi
  out="$(scan_content "$kind" "$pat")"; rc=$?
  if [[ $rc -eq 2 ]]; then bad=$((bad+1)); echo "UNUSABLE $label: the search failed or timed out, so its result cannot be trusted"; return 0; fi
  out="$(printf '%s\n' "$out" | grep -v '^$' || true)"
  if [[ -n "$out" ]]; then
    hits=$((hits+1)); total="$(printf '%s\n' "$out" | wc -l)"
    echo "HIT $label"; printf '%s\n' "$out" | head -5 | show_locations | sed 's/^/    /'
    [[ $total -gt 5 ]] && echo "    ... ($total locations)"
  fi
  if [[ -s "$tmp/extra" ]]; then
    grep -aqiE -e "$pat" "$tmp/extra" 2>/dev/null; rc=$?
    if [[ $rc -eq 0 ]]; then hits=$((hits+1)); echo "HIT $label in $extra_what (location withheld: it would repeat the identifier)"
    elif [[ $rc -ge 2 ]]; then bad=$((bad+1)); echo "UNUSABLE $label: the name and metadata search failed"; fi
  fi
  return 0
}
n=0; while IFS= read -r pat; do n=$((n+1)); scan_one generic "generic: $pat" "$pat"; done < "$tmp/generic.pats"
n=0; while IFS= read -r pat; do n=$((n+1)); scan_one local "local #$n" "$pat"; done < "$tmp/local.pats"

what="the working tree"; [[ $mode == history ]] && what="every commit"
if [[ $hits -gt 0 || $struct -gt 0 ]]; then echo "scan: $hits pattern(s) hit and $struct structural refusal(s) in $what: DO NOT PUBLISH"; exit 1; fi
if [[ $bad -gt 0 ]]; then echo "scan: $bad unusable pattern(s); the scan is incomplete and cannot attest" >&2; exit 2; fi
echo "scan: clean ($what; $ng generic + $nl local patterns)"; exit 0
