#!/usr/bin/env bash
# Refuse a merge that has neither a gate signature nor a second pair of eyes.
# See honesty-marker.md for what this is and is not.
#
# Usage: premerge-check.sh <pr-number> --as <session-id>
# Env:   KIT_GATE_REPO=owner/repo   (required)
#        KIT_SESSION_ID             (optional; if set it must equal --as)
# Exit:  0 may merge
#        1 refused: a rule failed, or a comment is ambiguous or unreadable (a person fixes it)
#        2 cannot attest: an input could not be read (the head, the commit status, the comments and
#          reviews) or who is merging is not established
#
# Passes only when ALL hold:
#   1. the PR head SHA carries a successful `local-ci/gate` commit status
#   2. at least one approval NAMES THE FULL HEAD COMMIT and comes from a different session than the
#      merger. A marker is the FIRST LINE of a PR comment, at column 0:
#          GATE-REVIEW: <session-id> <approve|reject> <head-sha> <note>
#      An approval carries the whole commit id (40 hex characters; 64 in a SHA-256 repository),
#      never an abbreviation. A short id is a 28-bit binding, and a different commit that shares the
#      first seven characters can be found in seconds. A marker that names another commit reviewed
#      different code and is ignored. Binding the approval to the commit means no clock is involved:
#      a backdated commit cannot make an old approval look fresh.
#   3. nothing blocks. These block: a reject that names the head by at least 7 hex characters, any
#      other verdict unless it names a FULL-length commit id that differs from the head in at least
#      8 places (a stale reject; a mistyped, short or missing id blocks), a non-approve marker that
#      cannot be read (an approve that cannot be used never blocks: it just does not count), two
#      markers in one comment, a line that looks like a marker but is not the first line
#      of its comment (unless every commit id on it is another full commit, as in a quoted old
#      reject), and a trusted reviewer's latest native review asking for changes. Inline comments on
#      a diff line and a native Approve are not read: put the marker in a comment or a review body.
#   4. comments and reviews from people without OWNER, MEMBER or COLLABORATOR association are
#      ignored, and so is an approval that was edited or minimized. That association is not a
#      permission check: a read-only organization member counts. Only an approval is ever muted.
# Everything uncertain fails CLOSED. Chain the merge on this with &&, never ;.
set -uo pipefail
export LC_ALL=C PYTHONIOENCODING=utf-8 PYTHONUTF8=1   # bytes for the shell; UTF-8 for the python helpers, whatever their version does under LC_ALL=C
for tool in awk base64 python3 gh; do command -v "$tool" >/dev/null 2>&1 || { echo "premerge: $tool is not installed. Cannot attest." >&2; exit 2; }; done
here="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.realpath(sys.argv[1])))' "$0")"   # follows a symlink to this script
pr=""; as_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --as) [ $# -ge 2 ] || { echo "usage: premerge-check.sh <pr-number> --as <session-id>" >&2; exit 2; }; as_id="$2"; shift 2 ;;
    *) [ -z "$pr" ] || { echo "usage: premerge-check.sh <pr-number> --as <session-id>  (one PR number only)" >&2; exit 2; }; pr="$1"; shift ;;
  esac
done
[ -n "$pr" ] || { echo "usage: premerge-check.sh <pr-number> --as <session-id>" >&2; exit 2; }
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "premerge: the PR number must be digits only" >&2; exit 2; }
if [ -n "$as_id" ] && [ -n "${KIT_SESSION_ID:-}" ] && [ "$as_id" != "$KIT_SESSION_ID" ]; then
  echo "premerge: --as and KIT_SESSION_ID disagree about who is merging. Cannot attest." >&2; exit 2
fi
me="${as_id:-${KIT_SESSION_ID:-}}"
id_ok() { [[ $1 =~ ^[A-Za-z0-9._:-]{3,64}$ && $1 == *[A-Za-z]* ]]; }   # one whole string; no per-line matching
canon() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }        # reviewer-session, Reviewer_Session. and .reviewer:session are one id
san() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:-' | cut -c1-64; }       # a comment must never reach the terminal raw
san_url() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:/#-' | cut -c1-120; }
if [ -z "$me" ] || ! id_ok "$me"; then
  echo "premerge: REFUSING. Cannot establish who is merging. Pass --as <your-session-id> (plain ASCII, 3 to 64 characters, at least one letter). --as is a claim, not an identity." >&2; exit 2
fi
[ -n "${KIT_GATE_REPO:-}" ] || { echo "premerge: set KIT_GATE_REPO=owner/repo. Cannot attest." >&2; exit 2; }
repo="$KIT_GATE_REPO"; fail=0
[ -f "$here/marker-parse.awk" ] || { echo "premerge: marker-parse.awk is missing next to this script. Cannot attest." >&2; exit 2; }

head_json="$(gh pr view "$pr" --repo "$repo" --json headRefOid 2>/dev/null)" || { echo "premerge: cannot read PR #$pr" >&2; exit 2; }
head="$(printf '%s' "$head_json" | python3 -c 'import sys, json; print(json.load(sys.stdin)["headRefOid"])' 2>/dev/null)"
[[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || { echo "premerge: PR #$pr has no readable head commit. Cannot attest." >&2; exit 2; }
echo "premerge: PR #$pr head=$head"

# per_page=100: the default page holds 30 contexts, and a busy head can push the gate status off it
status_json="$(gh api "repos/$repo/commits/$head/status?per_page=100" 2>/dev/null)" || { echo "premerge: cannot read the commit status of $head. Cannot attest." >&2; exit 2; }
state="$(printf '%s' "$status_json" | python3 -c 'import sys, json
d = json.load(sys.stdin)
s = [x.get("state") for x in d["statuses"] if x.get("context") == "local-ci/gate"]
print(s[0] if s else "")' 2>/dev/null)" || { echo "premerge: cannot parse the commit status of $head. Cannot attest." >&2; exit 2; }
case "$state" in
  success) echo "  [ok]   local-ci/gate = success on the head commit" ;;
  "") echo "  [FAIL] no local-ci/gate status on $head. Run gate-attest.sh --run on that commit." >&2; fail=1 ;;
  *) echo "  [FAIL] local-ci/gate = $(san "$state") on $head" >&2; fail=1 ;;
esac

cr_json="$(gh pr view "$pr" --repo "$repo" --json comments,reviews 2>/dev/null)" || { echo "premerge: cannot read the comments and reviews of PR #$pr. Cannot attest." >&2; exit 2; }
# One tab-separated row per text source: kind (C comment, R review body, X trusted reviewer whose
# latest decisive review asks for changes), association, minimized, edited, login, url, body in base64.
lines="$(printf '%s' "$cr_json" | python3 -c 'import sys, json, base64
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
d = json.load(sys.stdin)
def b64(s):
    return base64.b64encode((s or "").encode()).decode() or "-"
def clean(s, extra=""):
    return "".join(ch for ch in str(s) if (ch.isascii() and ch.isalnum()) or ch in "._:-" + extra) or "-"
def login(x):
    return clean((x.get("author") or {}).get("login") or "-")
def rawkey(r):   # the map key is the RAW login: two accounts must never share one after cleaning; a missing author is its own key
    a = (r.get("author") or {}).get("login")
    return a if a else "id:" + str(r.get("id"))
for c in d["comments"]:
    print("\t".join(["C", clean(c.get("authorAssociation") or "NONE"), "1" if c.get("isMinimized") else "0",
                     "1" if c.get("includesCreatedEdit") else "0", login(c), clean(c.get("url") or "-", "/#"), b64(c.get("body"))]))
latest = {}
for r in sorted((r for r in d["reviews"] if r.get("submittedAt")), key=lambda r: r["submittedAt"]):
    assoc = clean(r.get("authorAssociation") or "NONE")
    print("\t".join(["R", assoc, "0", "1" if r.get("includesCreatedEdit") else "0", login(r), "-", b64(r.get("body"))]))
    if assoc in TRUSTED and r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
        latest[rawkey(r)] = (r["state"], login(r))
for key, (st, who) in latest.items():
    if st == "CHANGES_REQUESTED":
        print("\t".join(["X", "-", "0", "0", who, "-", "-"]))' 2>/dev/null)" || { echo "premerge: cannot parse the comments and reviews of PR #$pr. Cannot attest." >&2; exit 2; }

ndiff() { local a="$1" b="$2" i d=0; for ((i = 0; i < ${#a}; i++)); do [ "${a:i:1}" = "${b:i:1}" ] || d=$((d + 1)); done; echo "$d"; }
# true only when the line names commits and EVERY commit id on it (7 or more hex characters) is a
# full-length id that differs from the head in 8 or more places: a quoted reject of an older commit
stale_line() {
  local toks t n=0
  toks="$(printf '%s' "$1" | grep -oE '[0-9a-f]{7,64}')" || return 1
  for t in $toks; do
    { [ "${#t}" -eq "${#head}" ] && [ "$(ndiff "$t" "$head")" -ge 8 ]; } || return 1
    n=$((n + 1))
  done
  [ "$n" -ge 1 ]
}
cands=""; blocks=""; strays=""; crq=""
ignored=0; muted=0; short=0; other=0; stray=0; ambiguous=0; repost=0
while IFS=$'\t' read -r kind assoc mini edited login url b64; do
  if [ "${kind:-}" = X ]; then crq="$crq $(san "$login")"; continue; fi
  { [ -n "${b64:-}" ] && [ "$b64" != "-" ]; } || continue
  case "$assoc" in OWNER|MEMBER|COLLABORATOR) ;; *) ignored=$((ignored+1)); continue ;; esac
  body="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" || { echo "premerge: cannot decode a comment of PR #$pr. Cannot attest." >&2; exit 2; }
  found="$(printf '%s\n' "$body" | awk -f "$here/marker-parse.awk")" || { echo "premerge: the marker parser failed on a comment of PR #$pr. Cannot attest." >&2; exit 2; }
  [ -n "$found" ] || continue
  [ "$(printf '%s\n' "$found" | grep -c '^GATE-REVIEW:' || true)" -le 1 ] || ambiguous=$((ambiguous+1))
  while IFS= read -r m; do
    case "$m" in
      STRAY|STRAY\ *)
        sline="${m#STRAY}"
        # the check's own usage line pasted into a comment is not a marker, and a quoted reject of an older commit is stale
        if [[ "$sline" == *"<its-session-id>"* || "$sline" == *"<session-id>"* ]] || stale_line "$sline"; then other=$((other+1)); continue; fi
        stray=$((stray+1)); strays="$strays $(san_url "$url")"; repost=1; continue ;;
    esac
    read -r t1 reviewer verdict msha note <<<"$m"
    if [ "$t1" = "GATE-REVIEW:" ] && [ "$verdict" = approve ]; then
      # an approve can never block, so an approve that cannot be used is just not an approval
      if [ "$msha" = "$head" ]; then
        # only an approval is ever muted: an edited or hidden reject still blocks
        if [ "$mini" = 1 ] || [ "$edited" = 1 ]; then muted=$((muted+1)); repost=1; continue; fi
        cands="$cands$reviewer"$'\t'"$note"$'\n'
      elif [[ "$msha" =~ ^[0-9a-f]{7,64}$ && "$head" == "$msha"* ]]; then short=$((short+1)); repost=1
      else other=$((other+1)); fi
    elif [ "$t1" = "GATE-REVIEW:" ] && [[ "$msha" =~ ^[0-9a-f]+$ ]] && [ "${#msha}" -eq "${#head}" ] && [ "$(ndiff "$msha" "$head")" -ge 8 ]; then
      other=$((other+1))      # a reject (or any non-approve) naming a FULL-length id far from the head: an older commit, stale
    elif [ "$t1" != "GATE-REVIEW:" ]; then
      blocks="$blocks  [FAIL] a GATE-REVIEW line is malformed: \"GATE-REVIEW:\" must be followed by a space and the session id"$'\n'; repost=1
    else
      # a reject, any other verdict, a near-miss or short or missing id: it blocks
      blocks="$blocks  [FAIL] GATE-REVIEW from $(san "${reviewer:-none}") is '$(san "${verdict:-none}")', not approve"$'\n'
    fi
  done <<<"$found"
done <<EOF2
$lines
EOF2

[ "$ignored" -eq 0 ] || echo "  [note] $ignored comment(s) or review(s) from people without OWNER, MEMBER or COLLABORATOR association were ignored"
[ "$muted" -eq 0 ] || echo "  [note] $muted approval(s) for the head were edited or minimized and are not trusted"
[ "$other" -eq 0 ] || echo "  [note] $other marker(s) name another commit or no readable commit and do not count"

if [ -n "$blocks" ]; then printf '%s' "$blocks" >&2; fail=1; fi
if [ "$ambiguous" -gt 0 ]; then echo "  [FAIL] $ambiguous comment(s) carry more than one GATE-REVIEW marker. Refusing rather than guessing which one counts." >&2; fail=1; fi
if [ "$stray" -gt 0 ]; then
  echo "  [FAIL] $stray line(s) look like a GATE-REVIEW marker but are not the first line of their comment, so they are not read as markers:${strays}" >&2
  echo "         A reject written that way would be ignored. Delete the comment and post a new one whose FIRST line is the marker." >&2; fail=1
fi
if [ -n "$crq" ]; then echo "  [FAIL] a trusted reviewer's latest native review asks for changes:${crq}. Dismiss it or have them approve." >&2; fail=1; fi

deny=" none self tbd todo xxx test reviewer session placeholder unknownsession "
good=0; reasons=""; first_ok=""
while IFS=$'\t' read -r reviewer note; do
  [ -n "$reviewer" ] || continue
  if ! id_ok "$reviewer" || [[ "$deny" == *" $(canon "$reviewer") "* ]]; then
    reasons="$reasons  [FAIL] GATE-REVIEW carries no usable reviewer id ('$(san "$reviewer")'). The reviewer must name itself in plain ASCII with at least one letter."$'\n'
  elif [ -z "$note" ]; then
    reasons="$reasons  [FAIL] GATE-REVIEW from $(san "$reviewer") says nothing about what was checked. A marker needs a note."$'\n'
  elif [ "$(canon "$reviewer")" = "$(canon "$me")" ]; then
    reasons="$reasons  [FAIL] GATE-REVIEW is from this same session ($(san "$reviewer")). Self-review is not review."$'\n'
  else
    good=$((good+1)); [ -n "$first_ok" ] || first_ok="$(san "$reviewer")"
  fi
done <<EOF3
$cands
EOF3
if [ "$good" -ge 1 ]; then
  echo "  [ok]   GATE-REVIEW approve of ${head:0:12} from $first_ok (merging as: $me)"
else
  if [ -n "$reasons" ]; then printf '%s' "$reasons" >&2
  elif [ "$short" -gt 0 ]; then echo "  [FAIL] $short approval(s) name the head commit by an abbreviation. An approval must carry the full commit id." >&2
  elif [ "$muted" -gt 0 ]; then echo "  [FAIL] the only approval(s) for the head commit were edited or minimized ($muted) and are not trusted." >&2
  elif [ "$other" -gt 0 ]; then echo "  [FAIL] none of the $other GATE-REVIEW marker(s) names the head commit ${head:0:12}: they reviewed other commits, or omit the commit." >&2
  else echo "  [FAIL] no GATE-REVIEW marker. Another session must post a comment whose FIRST LINE is:" >&2; fi
  echo "         GATE-REVIEW: <its-session-id> approve $head <what it actually checked>" >&2; fail=1
  [ "$repost" -eq 0 ] || echo "         An edited, abbreviated or malformed marker is not repaired by editing: delete that comment and post a new one whose first line is exactly the line above." >&2
fi
[ "$fail" -eq 0 ] || { echo "premerge: REFUSING. Do not merge #$pr." >&2; exit 1; }
echo "premerge: PR #$pr may be merged. Merge exactly this commit:"
echo "  gh pr merge $pr --repo $repo --match-head-commit $head"
