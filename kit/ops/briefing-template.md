# Machine briefing — <hostname> — READ FIRST

Condensed <date>. Everything here is a standing hazard or a verify command.
History lives in git and in `~/ops-history/`. Never pin an image digest or a
commit SHA here; they rot within hours. Give the command that reads the live value.

## This box SERVES PRODUCTION (since <date>)
- What routes through it, which units carry it, and the exact command that
  proves each is up. Which `docker stop`/`restart` takes down live traffic.
- Where rollback lives (stopped `-prev-<sha>` containers, tagged images) and the
  two prune commands that would delete it. Which timer is disabled for that reason.
- The deploy script. "Do not hand-roll a container swap."

## Identity tells
Two commands whose output has never been wrong (hostname, virtualization).
Paths that look like another machine's but are real here.

## Standing rules
Change sizing. Which other project on this box is a different project. Whether
sudo is passwordless, and what it is NOT permission for. Cross-machine etiquette (per-session
permissions; permission laundering). No internal links on public surfaces. Cost tiers.

## Network
Addresses, what the firewall does not protect, the one-liner that lists
anything bound beyond loopback.

## Scheduled jobs
The live data writer, the heartbeat, the backup (with its proven size, part
count, and the verify command), the monitor tier, the single fetcher. Then:
"This list is a sample, not the set" and the command that lists the set.

## Repo
Shared checkout is read-only by policy; the worktree recipe; branch namespace
per agent; the config keys that must stay empty; why branch cleanup is a trap;
the one worktree tree never to remove.

## Gate
Read the RESULT line as well as the exit code: a run can exit 0 having run nothing. Absent tools skip, not fail. Which job
hits live production. Baseline reds by date.

## Issues filed from this box (do not re-discover)
Closed ones with dates; open ones with the reason they are still open; the
settled-not-a-bug list that has bitten more than one session.
