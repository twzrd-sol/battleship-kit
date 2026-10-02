# battleship

One person, one Linux box, a fleet of AI coding agents from several vendors, and
more than a year of building, with real production running on that box since 2026-08-20. This is the way of working I use
now, published as a reference kit and a retrospective.

It is not a framework and it does not spin anything up. Every piece is
independently useful. Take one.

## What is in here

| Path | What it is | Adopt it when |
|---|---|---|
| `ESSAY.md` | The retrospective, with what the product has earned stated up front | you want the story before the tooling |
| `CLAIMS.md` | The numbers the docs state that can be re-derived, each with the command that produced it and the date; the rest are marked `needs_human` | you doubt a number (you should) |
| `LESSONS.md` | Seventeen operating lessons, nearly all earned by an incident | you run agents against anything that matters |
| `INCIDENTS.md` | The dated incidents behind the lessons and behind many of the files in `kit/` | you want the receipt for a rule |
| `test.sh` | The kit testing itself: hooks, timer, gate verdicts, leak gate, scripts. No network needed | before you trust any of it |
| `ADOPT.md` | The order to install the pieces, one evening each | you are starting |
| `kit/hooks/` | `pre-commit` refuses commits from the shared checkout; `pre-push` runs your local gate and refuses unless the pushed commit is the checked-out, clean HEAD | more than one agent touches one clone |
| `kit/timers/` | A fast-forward-only timer that keeps the shared checkout at origin/main and refuses when tracked files are changed | a shared checkout serves or seeds anything |
| `kit/agents/` | Three tiered agent roles with tool-call caps: scout, verify, worker | a driver session does lookups and checks itself |
| `kit/rules/` | Change sizing, secret handling, first-read | agents have production credentials |
| `kit/memory/` | The one-fact-per-file memory convention with hubs and an index | sessions forget what last week's sessions learned |
| `kit/bus/` | A file-based protocol for agents from different vendors to coordinate without touching each other's terminals | two agent CLIs share a box |
| `kit/ops/` | Status board (doc + script), gate recorder and attester, the merge check with the honesty marker, watchdog units, backup health, deploy guards, a machine-briefing template, and `mutate.py`, a mutation check that asks whether your tests could have failed | the box serves production |
| `scan.sh`, `denylist.generic.txt`, `export-public.sh`, `PUBLISHING.md` | The leak gate (tree and full history) and the snapshot exporter: a safer way to publish from a tree that was ever private, with stated limits (`PUBLISHING.md`). Your own identifiers live in a local list that never enters the repo | you publish anything from an internal tree |

## Prerequisites

bash, git 2.28 or newer (the tests use `git init -b`), and python3 3.8 or newer. The scripts avoid features newer than bash 3.2, but the suite has only been run here, on bash 5 and Linux. Optional: shellcheck (the self-test skips it when absent) and git 2.25 or newer for the sparse-checkout test.
`test.sh` needs no network, no GitHub, no Docker, and no systemd: the scripts
that call `gh`, `docker` or `curl` are tested against fakes. At runtime only the
timer install needs systemd-user (the status board reports null or unknown for what it
cannot read without systemctl, docker or curl), and `kit/ops/gate-attest.sh` and
`kit/ops/premerge-check.sh` need `gh`. The leak gate needs a local denylist of
your own (see `PUBLISHING.md`).

## The one idea

Agents are cheap and confident. Everything in this kit converts confidence into
evidence: a hook records the SHA it actually gated, a `verify` agent re-runs
another agent's command, a status board only carries numbers a human can
re-derive, a memory entry is meant to name the date and the command. When you cannot
verify, say `needs_human`, never `proven`.

## License

MIT. Copy freely, keep the honesty.
