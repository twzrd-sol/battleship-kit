# battleship-kit

A reference kit and a retrospective: one person, one Linux box (hostname
Battleship), a fleet of AI coding agents from several vendors, and more than a
year of building, with real production on that box since 2026-08-20.

This repository is the published snapshot (`twzrd-sol/battleship-kit`). The
sibling `twzrd-sol/battleship` is the same retrospective under the title "One
year, one box: reference kit and retrospective for running production with an
AI agent fleet". Adopt **this** tree; the sibling is an older snapshot and
does not yet carry the 2026-10-05/06 operator receipts.

It is not a framework and it does not spin anything up. Every piece is
independently useful. Take one. The sections below also record how the origin
box is wired, so a new operator can keep it up without guessing.

## What this kit is

- A way of working: convert an agent's confidence into evidence you can re-run.
- Tested scripts and hooks you copy into your own trees (`ADOPT.md`).
- Dated incidents and lessons, including how this box failed and recovered.
- Not an installer for Battleship. Do not treat a green `./test.sh` as proof
  that production is up.

## The hosts

| Host | What it is | What a new operator must not do |
|---|---|---|
| **Battleship** (linux_amd64) | The production machine. Serves the public sites, the Radio LAN hub and station, the TWZRD API and intel edge, Docker production containers, the shared git checkout, worktrees, and the agent fleet. | Do not reboot it, prune Docker, or restart the TWZRD tunnel to debug Radio LAN. |
| **Operator Mac** (darwin_arm64) | The operator's laptop. Fine for git, review, and `launchctl` cleanup. | Do not run a `cloudflared` connector for a production tunnel from this machine. A forgotten LaunchDaemon did that once and Cloudflare split traffic onto a host with no origin. |
| **Cloudflare edge** | Public hostnames. Each hostname should belong to **one** tunnel, and each tunnel should have **one** connector. | Do not trust origin logs alone. Caddy can log 200 while a third of public requests return Cloudflare `error code: 502`. |
| **Old rented host** | Frozen standby after the 2026-08-20 move. The provider later shut it off. | Do not treat SSH-up or a script exit 0 against leftover references as "the box is fine". |

One tunnel, one host, one connector. A single `cloudflared` normally holds
**four** edge connections. **Eight** connections on one tunnel means two
connectors.

## The services (Battleship)

Radio LAN, public hostname `radiolan.live`:

| Piece | Unit or path | What it does |
|---|---|---|
| Caddy edge | user unit `caddy-frontend-staging.service`, config `~/.config/caddy/Caddyfile.frontend`, loopback port 8080 | Terminates HTTP on the box. Serves static `/hub` from the disk serve tree (`~/radiolan-hub-serve`). Proxies `/hub/api` and `/hub/rpc` to the station. `/` and `/stream` redirect to `/hub`. |
| Station | user unit `radiolan-station.service`, loopback port 8787, serve worktree `~/worktrees/radiolan-station` | API and RPC only. It does **not** serve the hub HTML. Restarting it blips `/hub/api` for about a second; static `/hub` stays up. |
| Radio LAN tunnel | system unit `cloudflared.service`, tunnel name `radiolan-battleship` | Cloudflare hostname `radiolan.live` → `http://127.0.0.1:8080`. Token lives in the secret manager and the unit's token file; never print it. |
| Old hub URL | `twzrd.xyz/hub` and `/stream` | 308 to `https://radiolan.live/hub`. |

TWZRD production (same box, **different** tunnel):

| Piece | Unit or path | What it does |
|---|---|---|
| TWZRD tunnel | user unit `cloudflared-battleship.service`, local config `~/.cloudflared/config.yml` | `twzrd.xyz`, `api`, `intel`, `/wv`, `/research`. Do not edit or restart this unit to work on Radio LAN. |
| Production containers | names in `KIT_PROD_CONTAINERS` and the machine briefing | The API, database, and related images. Rollback is the stopped `-prev-<sha>` container. Never `docker prune`. |

Also on the box, not Radio LAN:

| Piece | Note |
|---|---|
| Tunnel `outbid-sh` | Same check that found the stray Mac connector showed **eight** connections and two processes (`outbid-cloudflared.service` and `outbid-tunnel.service`) on the same config. Treat that as a **likely duplicate to review**. Do not claim it is broken. |
| Shared git checkout | Fast-forward-only. Feature work in named worktrees. |
| Status board | `~/.config/kit/status.json`, rewritten every few minutes. |
| Hardware watchdog | Units in `kit/ops/watchdog/` are drafts. Confirm the device exists after every reboot. |

## How to check health

Read the status board first (`kit/ops/status-board.md`, `kit/rules/03-first-read.md`).
If `generated_at` is older than `valid_for_seconds`, treat the color as unknown.
After a reboot, compare `generated_at` with the clock.

Then prove the live path with **curl**, not a Python HTTP client. Python
clients that hit Cloudflare can get error **1010** (browser integrity check).
That is not an origin failure.

```bash
# Public edge. Expect 200 and a hub page, not the body "error code: 502".
curl -sS -o /tmp/hub-body -w '%{http_code}\n' https://radiolan.live/hub/

# Intermittent public 502: sample, do not take one hit.
for i in $(seq 1 30); do curl -sS -o /dev/null -w '%{http_code}\n' https://radiolan.live/hub/; done

# Origin on the box. 200 here plus edge 502 means the tunnel, not Caddy.
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/hub/

# Static vs API. Station restarts leave /hub at 200 and blip /hub/api only.
curl -sS -o /dev/null -w '%{http_code}\n' https://radiolan.live/hub/api/

# Other production hostnames still answer (do not restart their tunnel to check).
curl -sS -o /dev/null -w '%{http_code}\n' https://twzrd.xyz/hub/     # 308 to radiolan.live
curl -sS -o /dev/null -w '%{http_code}\n' https://twzrd.xyz/wv       # still the locked page
```

Tunnel connectors — pass the **UUID**, and ignore any default config file.
`cloudflared tunnel info <name>` with `~/.cloudflared/config.yml` present has
returned the **wrong** tunnel.

```bash
cloudflared tunnel info <tunnel-uuid> --config /dev/null
```

Count connectors, their OS/arch, and origin IP. Battleship should be
`linux_amd64` with an origin. A `darwin_arm64` connector is the laptop; it
should not be there. Four edge connections is one connector; eight is two.

Units and containers:

```bash
systemctl --user status caddy-frontend-staging.service radiolan-station.service
systemctl status cloudflared.service
systemctl --user status cloudflared-battleship.service   # look, do not restart
docker ps --format '{{.Names}}\t{{.Status}}'             # only the configured production names
```

Caddy 200s plus a healthy Battleship `cloudflared` are **not** enough. The
2026-10-05/06 502s were a second connector on the same tunnel. Full receipts
are in `LESSONS.md` (dated section) and `INCIDENTS.md`.

## How to recover

| Symptom | Likely cause | What to do | What not to do |
|---|---|---|---|
| Public `/hub` is Cloudflare 502 (`error code: 502`) on some requests; Caddy logs 200; Battleship `cloudflared` looks healthy | A second connector on tunnel `radiolan-battleship` (once: a Mac LaunchDaemon `com.cloudflare.cloudflared`, token-run, no origin) | On the Mac: `sudo launchctl bootout system/com.cloudflare.cloudflared`, then move that plist out of `/Library/LaunchDaemons`. Re-check `cloudflared tunnel info <tunnel-uuid> --config /dev/null`. Confirm 30/30 public 200s. | Do not restart Caddy, the station, or `cloudflared-battleship.service`. Do not rotate tokens from a prompt. |
| `/hub` is 200, `/hub/api` blips for about a second | `radiolan-station` restart (five times 08:45–09:11 UTC on 2026-10-06, then again at 09:22) | Wait; confirm API 200 with curl. Static files are served from disk and are not the station. | Do not treat a static 200 as "the API is fine", and do not treat an API blip as "the site is down". |
| Public 502 and origin on :8080 is also down | Caddy or a container swap that stopped the listener | Restore the Caddyfile backup and reload the user unit, or start the stopped `-prev-<sha>` container (`kit/ops/deploy-guards.md`). | Do not `docker run` a replacement by hand. Do not prune stopped containers. |
| Production container name collision after stop, before run | Redeploy of an already-deployed SHA | Start the stopped container. Fix the swap script so it checks the `-prev-` name **before** the stop. | Do not assume a Cloudflare 502 is this; prove origin vs edge first. |
| Status board still green after a reboot | Stale file; the timer did not rewrite it | Compare `generated_at` with the clock. Re-run the generator. | Do not trust a green color on an old board. |
| Need to remove worktrees | Sprawl (173 linked trees on one repo as of 2026-10-06) | For each tree: dirty files, open PRs, running processes. Record recovery commits first. Then prune. | Do not remove a worktree to make a test pass. Nine hundred uncommitted lines were once destroyed that way. |
| Python probe says Cloudflare 1010 | Browser integrity check, not the origin | Use curl. | Do not restart services on a 1010. |

Unattended sessions do not mutate production containers, the live database, or
tunnel tokens (`kit/rules/02-secret-handling.md`). Work attended, one verified
step at a time.

## What is in here

| Path | What it is | Adopt it when |
|---|---|---|
| `ESSAY.md` | The retrospective, with what the product has earned stated up front | you want the story before the tooling |
| `CLAIMS.md` | The numbers the docs state that can be re-derived, each with the command that produced it and the date; the rest are marked `needs_human` | you doubt a number (you should) |
| `LESSONS.md` | Seventeen operating lessons, nearly all earned by an incident, plus dated operator receipts from 2026-10-05/06 | you run agents against anything that matters |
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
