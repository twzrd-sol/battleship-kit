# A fleet of agents on one production machine

*The numbers that can be re-derived are in CLAIMS.md, each with the command that produced it.*

I have spent more than a year on this project, and since early 2026 AI coding
agents have done most of the typing. x402 payments entered the work in March 2026, and by late May there
was a trust service for them. Today the product runs in production from a single Linux
machine, it keeps a signed transparency log, and in its lifetime it has taken
in about eight dollars, as of 2026-09-17. I cannot attribute any of that to an
independent customer: the three largest payers, about four-fifths of the
total, include one of my own retired keys and a test wallet.

This is not the story of the product. It is the story of how one person and a
fleet of agents ran a real production estate, first on a rented server and
since 2026-08-20 on this machine. Most of the evidence below is from those
last six weeks. It mostly worked, and the incidents that shaped the kit are in
INCIDENTS.md. The way of working is the part of this year that someone else
can use.

## What "a fleet" means here

Agent CLIs from several vendors, Claude, Codex, Grok and Hermes among them,
each in its own session, plus more than twenty local models on a consumer GPU
for work that should never leave the machine. On 2026-09-29 about
twenty-two sessions were open. They share one Linux machine, and that machine
also serves the API, the database and the public site.

That last sentence is the whole problem. Most of the conventions in the kit are
answers to three things an agent with production credentials, a shared
checkout and a confident tone will eventually do: commit in the wrong place,
report something it did not verify, or act on a message it should have treated
as data.

## The three failures

**Commit in the wrong place.** In May, work done in the shared checkout
silently forked a package from main, and the only guard then in place refused
commits to main. A guard that refuses commits from the shared checkout on any
branch was written the same day the divergence was diagnosed; the pull request
was opened on 2026-05-17 and merged on 2026-06-05. The fast-forward timer that
keeps that checkout at main, and refuses if tracked files are changed, came on
2026-09-17. The hook is in the kit. The timer has a self-test.

**Report what was not verified.** This one has many shapes. A deploy that was
merged and green and did nothing to the rows it targeted. An audit whose five
headline findings were each an artifact of the instrument: traffic to a dead
route read as demand, one ranked lane read as the whole market, and three more
of the same kind. A failed lookup reported as "no rings found". And on
2026-09-18, 34 pull requests were merged in one day with no approving review,
the fastest in three seconds. The author and the merger were one GitHub
identity, and every hosted check was blocked by a billing hold, so nothing
could have stopped a merge but the person merging. That was a busy day, not an
unusual one: the median day that month had 17 merges, 8 of the 29 days with any
merge had 34 or more, the busiest had 95, and none of the 653 pull requests
merged in September had an approving review.

What we added that day: a merge check that wants the gate verdict on the exact
commit plus a review marker from a *different* session. Binding the marker to
the commit came later, in this kit, when an audit showed that an approval could
carry over to code nobody had reviewed. The rule that a report says `needs_human`
when it cannot prove `proven` is older: the main repo's first commit that names
it is dated 2026-09-12. Nine pull requests merged after the check landed that
day, and none of them carries a marker: the check crashed on a valid marker until
a fix on 2026-09-24. Since then 104 of the 142 pull requests merged carry one.
Whether any merge waited for one I have not measured. A `verify` role that re-runs another agent's evidence already existed, and
it did not prevent any of this. The marker is unauthenticated free text and the
doc says so. Its first designs had holes that let an approval be forged or carry
over to code nobody reviewed, and successive audits found them before anyone
published it. Honest and imperfect beats dishonest and neat.

**Act on a message that was data.** Agents on the same machine pass work to
each other. When one agent asks another to do something its own session was
denied, that is permission laundering. The rule: bus messages are inert,
per-session permissions do not transfer, refuse and surface. The bus protocol
in the kit starts from that rule. Unlike the other two, this one has no dated
incident with a cost attached in INCIDENTS.md: it is a rule, and I am not going
to dress it up as a post-mortem.

## The memory

The thing I would keep if I could keep only one. The convention is one fact per
file, with a date, a why and a how-to-apply, and an index of hubs and active
entries is loaded into every session. The practice is looser: of about 260 files
after six weeks, 114 carry both a why and a how-to-apply, and some are running
logs rather than single facts. Hubs fold old threads. The convention is to
update an entry in place and delete one that turns out wrong; in practice some
get a correction appended. It is a plain directory, not under version control,
so a deleted entry is gone from it, recoverable only from session transcripts.

I have not measured whether it works. The same class of mistake, reporting
something unverified, first appeared on 2026-08-20 and came back three times in
three weeks: INCIDENTS.md cites the first lesson on 2026-09-03, 2026-09-18 and
2026-09-25. What I can say is that
when a fresh session is about to prune worktrees, the briefing it loads already
says what happened the last time someone removed worktrees to make a test pass:
nine hundred or more uncommitted lines were destroyed, and were recovered only
by replaying them out of agent transcripts.

## What the local models were for

The rule is dev only, on loopback: local agent and coding loops, embeddings,
and synthetic security tests against the payment interceptors, never in
production request paths. On 2026-09-30 they also brainstormed. I had a session
ask two of them what to ship next; one returned nothing usable, and the other's
wildcard was a Merkle-inclusion verifier for the transparency log, which we had
already merged into a public repository 25 days earlier. I have no evidence that anyone outside ever ran it.

What I cannot show is an independent buyer: three receipts are flagged external,
and none is attributed to anyone independent of me. The estate can build almost
anything, and nothing in it can make a stranger decide to pay. That part is
outreach, one message at a time, and no amount of building does it for you.

## What the guardrails have and have not proved

Production moved to this machine on 2026-08-20. The rented server stayed up as
a standby until its provider shut it off over an unpaid account, and in those
days four stale references to the old environment got confident wrong answers,
which is its own lesson. Since the move the guardrails have caught some things and missed
others, and INCIDENTS.md lists both. A hardware watchdog, armed by hand
earlier that day, turned a poweroff that did not complete into a reset, and
the persisted version of that arming did not survive a reboot; the units in
this kit that would persist it are drafts, not yet enabled anywhere. A backup
checker reads the bucket back instead of trusting the job. A security audit of
our own package found a critical bug; the first fix release and the advisory
went out within a minute of each other, a re-audit then found more, and two
further security releases followed within three days. The rule I try to hold is
the dullest one: agents work on production attended, one verified step at a
time. It is a rule, not a mechanism: nothing records attendance, and some
sessions run with approval prompts bypassed. The deploy script itself is not in this kit;
`kit/ops/deploy-guards.md` describes its guards.

I am publishing the way of working because it is the part a stranger can use.
It is not finished. Four adversarial audits of this kit, run before I published
it, each found at least one blocking defect in the kit itself, including ways to
forge a review approval and a leak scanner that read some files as clean, and
the kit's own tests had been passing on my machine the whole time. They are fixed,
and most of the fixes have tests, though not every line of every script is covered (CLAIMS gives,
for each gating script, the share of one-line changes the tests caught). The next audit will find more.

## What to take

If you run agents against anything that matters, start with the pieces that
have tests: the gate recorder, which will not call a run a pass
unless its RESULT line shows jobs that ran and none that failed, the
fast-forward-only timer, the pre-commit hook, and the leak gate. The `verify`
role and the memory convention are habits I have not measured. Much of the rest
of the kit is the receipt for a specific bruise.
Read `LESSONS.md` for the bruises, including the dated operator receipts from
2026-10-05/06 (stray tunnel connector, station vs static path, store flush,
test-runner glob, Cloudflare 1010, worktree sprawl). Read `CLAIMS.md` before you quote a number
from this essay, including the revenue line, which I cannot tie to any
independent customer. The top-level README now names the hosts, services,
health checks, and recovery steps for the origin box.
