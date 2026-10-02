# Seventeen lessons, each paid for

Written as memory entries: the fact, why, and how to apply it.

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
