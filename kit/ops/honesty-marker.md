# The honesty marker

When author and merger are the same GitHub identity, GitHub's review machinery
cannot express separation of duties. Do not pretend it can.

What we do instead: a merge is refused unless (1) the PR head SHA carries a
successful gate commit status published from a real local run on that exact
SHA, and (2) a peer marker approves that same SHA and comes from a *different
named session* than the merger. The marker is the FIRST LINE of a PR comment,
at column 0:

    GATE-REVIEW: <session-id> <approve|reject> <head-sha> <note>

An approval carries the WHOLE commit id, 40 lowercase hex characters (64 in a
SHA-256 repository). An abbreviation is refused. A seven-character id is a
28-bit binding: a different commit that shares those characters can be found in
seconds, so an approval of the real commit would transfer to it. A marker that
names another commit reviewed different code and is ignored. That ties the
approval to the code, and it removes the clock: an earlier version compared the
comment's time with the head commit's date, which the pusher writes, so a
backdated commit made an old approval look fresh. A reject of an old commit plus
an approval of the head is fine, because the old reject is stale.

A marker is live only on the first line. Two things beyond that make the check
stricter, never looser. A second `GATE-REVIEW:` line after a live first line
makes the comment ambiguous and the check refuses it. A line that LOOKS like a
marker but is not live (indented, quoted, bold, bulleted, lower case, after a
byte-order mark, after an emoji, a pipe, a tag or a label, or simply on a later
line) is reported and refuses the merge until the comment is deleted and
reposted, because a reviewer who meant a reject and put it in the wrong place
must not be ignored without a word. Two exceptions keep honest comments from
being refused: a line whose every commit id is another full commit (a quoted
reject of an older commit, as Quote reply produces) is stale like any other, and
the check's own usage line pasted into a comment is not a marker. A sentence that
mentions the word without a verdict or a commit id is not marker-shaped and is
not reported. The Unicode line separators U+2028, U+2029 and U+0085 count as line
breaks. Inline comments on a diff line are not read at all, and neither is a
native Approve review: put the marker in a comment or a review body. Look-alike characters (a non-breaking hyphen, a Cyrillic letter) are
not detected; the parser reads ASCII. All of this was learned the hard way. The
first parser tried to read Markdown the way GitHub renders it (fences, quotes,
HTML blocks, comments, link definitions) and lost to the renderer repeatedly,
twice in ways that let an approval be forged. A first line cannot be inside a
construct that opened on an earlier line, so there is nothing to model and
nothing to forge.

A reject blocks. Any verdict other than exactly `approve` blocks, unless it is
clearly stale. A reject is stale, and ignored, only when it names a FULL-length
commit id (40 hex characters, or 64) that differs from the head in at least
eight places, which is what a different commit looks like. A mistyped id, an
extra character, a short id, a note word that happens to look like hex, or no id
at all is not that, so it blocks. An approve that cannot be used (an abbreviated
id, punctuation, no id, another commit) never blocks, because an approve cannot;
it simply does not count. To retract a reject, delete the comment. Editing or
hiding it does not clear it. A refusal caused by an edited, abbreviated or
malformed marker is not repaired by editing: delete the comment and post a new
one whose first line is exactly the line the check prints.

Who counts. Comments and reviews from people without OWNER, MEMBER or
COLLABORATOR association are ignored. That is GitHub's association, not a
permission check: an organization member with read-only access has MEMBER and
their approval counts. If that matters in your repository, treat the marker as
advisory (below) or limit who can comment. An approve that was edited or
minimized is not trusted. Only an approve is ever muted; a reject is never
dropped, because blocking is the safe direction. Native GitHub reviews are read
too: a trusted reviewer whose latest approving, requesting or dismissing review
is "Request changes" blocks the merge, and a later plain comment review does
not clear it. A reject written as the first line of a review body blocks like
one in a comment. A reviewer id is plain ASCII, 3 to 64 characters, with at
least one letter, and not a placeholder such as `none` or `test`. The marker
needs a note saying what was checked. Those rules exist because an unsatisfiable
gate is one people route around, and a gate satisfied by any string is no gate.

Exit codes. 0 means the merge may go ahead. 1 is a refusal: a rule failed, or a
comment is ambiguous or unreadable, and a person can fix it. 2 means the check
cannot attest because it could not read an input: the head, the commit status,
the comments and reviews, a PR number that is not digits, `--as` that
contradicts `KIT_SESSION_ID`, or who is merging. Neither is ever 0. On success
the check prints the merge command to use, `gh pr merge <n> --repo <owner/repo>
--match-head-commit <sha>`, so a push after the check cannot be merged by the same approval.

What it is not. Both legs are advisory against whoever holds the token. The
reviewer id is unauthenticated free text, `--as` is a claim, and when one GitHub
identity runs the whole fleet the same hand can post the status and the marker.
It records a claim; it does not verify one. The real control is a second GitHub
identity with write access that the author cannot use. Until you have one, this
is a speed bump that makes a self-merge take two deliberate steps instead of
none.

What was measured, and when. On 2026-09-18, the day the first version of this
check landed (15:15Z), 34 PRs were merged, none with an approving review, the
author and the merger the same GitHub identity every time. 24 were merged before
the check (a median of 2.7 minutes from open to merge, a fastest of 3 seconds);
the check's own PR and 9 more merged at or after it, and none of those 9 carries
a marker (the commands are in `CLAIMS.md`). That day was ordinary for that month,
not an incident: 8 of the 29 days with any merge had 34 or more, the busiest had
95, and none of the 653 PRs merged in September had an approving review. Use of
the check since has not been measured.

The scripts: `gate-record.sh` derives the verdict from the RESULT line,
`gate-attest.sh` publishes it as a commit status (only `--run` may say `all`,
and only on a clean tree), `premerge-check.sh` refuses the merge without both
the status and the marker.

When the checker is itself the file under review, run both the stock checker
(from main) and the branch's checker against the PR and record both verdicts
in the merge note. The night this kit's parser was fixed, main's copy could not
see the reviewer's markers at all; the merges were decided by the branch copy,
and the record has to say so.

Chaining rule: never join the check and the merge with `;`, and put no pipe
between them. Use `&&` so a refusal stops the merge.
