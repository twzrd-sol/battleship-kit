# Seventeen lessons, each paid for

Written as memory entries: the fact, why, and how to apply it. The dated
receipts after item 17 are later incidents (2026-10-05/06), written as
symptom, cause, how it was found, fix, and prevention. They do not change
the count of numbered lessons.

1. **Merged and green is not verified.** A change deployed cleanly and did
   nothing to the rows it was written for. *Apply:* after every deploy, read
   one artifact the change should have altered.

2. **Null results read as findings.** Five headlines in one audit were each an
   artifact of the instrument: traffic to a dead route, one ranked lane read as
   the whole market, and three more of the same kind.
   *Apply:* before reporting an absence, prove the instrument could have seen a
   presence.

3. **Capability reported as evaluation.** A lookup that failed was reported as
   "zero rings found". *Apply:* `null` means never evaluated; only `false` means
   clean. Keep the two values distinct all the way to the UI.

4. **Comparing two copies of a fact proves nothing.** A byte-identity check
   between an image and its own stale checkout passed, and both were wrong.
   *Apply:* one side of every pin check must be the live thing.

5. **Silent truncation voids negative evidence.** Capped output looks complete.
   *Apply:* every list you reason from carries its own count and its cap.

6. **Open is not live, and live is not on main.** Open issues were often already
   fixed; production once ran a commit that existed on no branch. *Apply:* grep
   origin/main before working an issue; confirm the live SHA is on main before
   trusting a rollback.

7. **A missing installer is a missing job.** A unit that was written but never
   installed had "run" in every status report. *Apply:* absent from the
   scheduler means it never ran. Check the scheduler, not the repo.

8. **Worktree-served units go stale.** Distance in commits is not the question.
   *Apply:* verify by the content of the executed path, and give the serve tree
   one writer.

9. **Branch cleanup is a trap under squash-merge.** Merged and abandoned
   branches look identical by ancestry. *Apply:* verify by content and PR state,
   and scan every worktree for uncommitted work before any sweep. Nine hundred
   lines were once destroyed by a test that "just needed the trees gone", and
   were recovered only by replaying them out of agent transcripts.

10. **A peer's approval is not approval.** Relaying a task another session was
    denied is permission laundering. *Apply:* per-session permissions; refuse
    and surface.

11. **Rank ideas by the outside dollar.** Infrastructure fit and model agreement
    are not demand. On 2026-09-30 a local model proposed, as a novel wildcard,
    a tool we had already shipped 25 days earlier; I have no evidence anyone outside ran it.
    *Apply:* name the payer before building; a control's defaults decide more
    than its options.

12. **Make the deliverable durable before the long call.** A reviewer call or a
    subagent can outlive the session. *Apply:* write the file, commit the
    change, then ask for review.

13. **A branch that prints must re-check every "inert" state.** A parser fix
    guarded on one flag and printed inside two other hidden contexts. Then the
    reviewer's own note mentioned a tag mid-sentence and the parser hid the
    review. *Apply:* when adding an early-exit or early-print path, re-run every
    hidden-context test against it, and anchor block openers to where the spec
    says they open. The durable answer turned out to be lesson 16.

14. **Gate on the exit code of the command that matters.** `test.sh | grep
    RESULT && push` pushed a red test; `gh pr merge | tail && echo MERGED`
    announced a merge that GitHub had refused. Both times the pipe's last
    command succeeded. *Apply:* `if cmd >out 2>&1; then` and read `out`; never
    put a pipe between the command that matters and `&&`.

15. **The list of what must not leak is itself a leak.** A leak gate shipped
    with its denylist inside the tree it guarded, excluded from its own scan:
    every internal name it protected sat in every commit, one visibility flip
    from public. Found before it mattered, by asking what a hostile reader
    would find in the history instead of the tree. *Apply:* keep identifiers in
    a list outside the repository, scan history as well as the tree, never
    print a pattern or matched text from a failing scan, and publish a
    one-commit snapshot instead of flipping a repo that was ever private.
    Corollary found the same night: a pattern that starts with `#` was read as
    a comment, so the ticket-number check had never run.

16. **When a parser has to agree with a renderer, read less.** The honesty-marker
    parser modelled Markdown: fences, quotes, HTML blocks, comments, link
    definitions. It was fixed over and over in one night, and an audit then found
    two more ways to forge an approval, because the renderer's grammar is larger
    than any script's idea of it and every fix opened the next hole. What held was
    to stop modelling: a marker counts only as the first line of a comment, where
    nothing earlier can hide it. *Apply:* when your check and a renderer must
    agree about what a human sees, shrink the surface your check reads until
    there is nothing left to disagree about, and fail closed on everything else.
    A second audit finding belongs here: tests that pass prove only the cases you
    thought of. Have someone who is not you attack what you are about to publish.

17. **A green suite is a claim; try to make it red.** Four audit rounds found
    blocking defects in this kit while every test passed. A mutation run
    (`kit/ops/mutate.py`: change one line of a script, rerun the tests) then showed
    where the tests could not have failed: refusals whose exit code nobody
    checked, a fallback that quietly became a fail-open, an error message that
    printed its own prefix twice. Writing the test for one survivor exposed a bug in
    that day's own refactor: a search that put its revisions after `--` and looked
    at nothing. *Apply:* before you trust a gate, change a line of it and see which
    test notices. For each line nothing notices, write the test, delete the line,
    or write down why it does not matter. Then do the same to the harness.

## Operator receipts, 2026-10-05 and 2026-10-06

These happened on the origin box after the numbered list was frozen. Service
names and paths are listed so a new operator can run the same checks. Tokens,
keys, and token-file contents are not.

### Cloudflare tunnel stray connector (2026-10-05/06)

**Symptom.** `https://radiolan.live/hub` returned Cloudflare 502 (body
`error code: 502`) on about a third of requests. Caddy on Battleship logged
only 200s. The Battleship `cloudflared` for tunnel `radiolan-battleship`
looked healthy.

**Cause.** Cloudflare was load-balancing to two connectors. One was
Battleship (`linux_amd64`) with Caddy behind it. The other was a forgotten
`darwin_arm64` LaunchDaemon on the operator's Mac (`com.cloudflare.cloudflared`,
token-run) with no origin. The Mac connector answered from the edge and had
nothing to proxy.

**How it was found.** `cloudflared tunnel info <tunnel-uuid> --config /dev/null`
listed two connectors, two architectures, and one origin-less Mac. Using the
tunnel **name** while a default `~/.cloudflared/config.yml` was present
returned the **wrong** tunnel; pass the UUID and `--config /dev/null`. The
same check showed tunnel `outbid-sh` with eight edge connections and two
`cloudflared` processes on Battleship (`outbid-cloudflared.service` and
`outbid-tunnel.service`) sharing one config. Flag that as a likely duplicate
to review; do not claim it is broken.

**Fix.** On the Mac: `sudo launchctl bootout system/com.cloudflare.cloudflared`,
then move that plist out of `/Library/LaunchDaemons`. After that, 30/30 public
requests returned 200.

**Prevention.** One host per tunnel, one connector per tunnel. A single
`cloudflared` normally holds four edge connections; eight on one tunnel means
two connectors. Put connector count, OS/arch, and origin IP in the health
check (see the top-level README). Never run a production connector from the
operator laptop. Never diagnose a public 502 from Caddy logs alone.

### Unattended station restarts (2026-10-06)

**Symptom.** `radiolan-station` restarted five times between 08:45 and 09:11
UTC, and again at 09:22. Public `/hub` stayed up.

**Cause.** The hub HTML is static files Caddy serves from disk. Only
`/hub/api` (and `/hub/rpc`) go to the station. A station restart blips those
paths for about one second.

**How it was found.** Unit journals showed the restart burst. Curl to `/hub`
stayed 200 while `/hub/api` dropped.

**Fix.** None required for the static site. Wait for the station to come
back; confirm `/hub/api` with curl. Find why the unit restarted before the
next unattended burst.

**Prevention.** When diagnosing "the hub is down", probe static `/hub` and
`/hub/api` separately. Do not restart Caddy or the tunnel for an API-only
blip. Do not treat a static 200 as proof the API is healthy.

### Async store flush race (Radio LAN product repo, pull 146)

**Symptom.** A restart test rebuilt the API on the same store path and got
`quote_not_found` (404). The write that should have been on disk was not.

**Cause.** Making the store flush async by default returned from the request
before the write landed. The next instance opened the same path and did not
see the quote.

**How it was found.** The product repo's `test` check went red on pull 146.
The comment on that pull is the receipt: default flush is sync again.

**Fix.** Keep sync flush as the default. Opt into async only where a caller
needs it (the live station passes `asyncFlush: true` only when that payment
path is enabled). Tests await `flushed()` before opening a second instance
on the same path.

**Prevention.** A default that returns before durability is visible will
pass the happy path and fail the first restart test. Do not flip a store to
async "for speed" without an await point the next reader can use.

### Test runner mismatch (Radio LAN product repo, pull 152)

**Symptom.** The root `node --test` glob picked up a vitest spec under
`apps/hub/test` and crashed: `Cannot find package 'vitest'`.

**Cause.** Two runners, one tree. `node --test` globs files the other
runner owns. The root job does not install vitest.

**How it was found.** The crash named the vitest spec path. The hub's own
vitest run was not the job that failed.

**Fix.** Keep each runner's files in paths only that runner globs. Do not
put `*.test.ts` / vitest specs where `node --test` will see them.

**Prevention.** When you add a spec, say which command is supposed to run
it, and run the *other* suite once to prove it ignores the file.

### Python probes vs Cloudflare 1010 (2026-10-05/06)

**Symptom.** A Python HTTP client hitting a Cloudflare hostname returned
error 1010 (browser integrity check). It looked like the origin was refusing
the request.

**Cause.** Cloudflare's browser check, not Caddy and not the station.

**How it was found.** The same URL returned 200 from curl while Python
failed.

**Fix.** Use curl for health probes (`curl -sS -o /dev/null -w '%{http_code}\n'`).

**Prevention.** Do not restart services on a 1010. Do not put a Python
`urllib` / `requests` probe in the status board path that decides whether
production is up.

### Worktree sprawl (173 linked trees, 2026-10-06)

**Symptom.** One repository had 173 linked worktrees (CLAIMS still records
154 as of 2026-10-01; the count grew). A sweep looked cheap.

**Cause.** Agents add worktrees and do not take them down. Under
squash-merge, merged and abandoned branches look the same by ancestry
(lesson 9). A "just delete them" pass will hit dirty trees, trees that
still have an open PR, and trees whose process is still serving.

**How it was found.** `git worktree list` counted 173. Lesson 9 is the
prior receipt: a session once removed four trees to make a pin test pass
and destroyed 900 or more uncommitted lines.

**Fix.** Do not sweep yet. For each tree: dirty files, open PRs, running
processes. Record recovery commits first. Then prune only what those three
checks clear.

**Prevention.** Same as lesson 9, with a number attached: never remove a
worktree to make a test pass, and never prune by count. The briefing should
name the trees that serve production (`~/worktrees/radiolan-station` is
one) and refuse a sweep that includes them.
