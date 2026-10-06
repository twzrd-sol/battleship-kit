# Deploy guards

A container swap on a box that serves production needs several independent
refusals. They look redundant. Each was added after a real case the others
missed.

## The swap itself

`stop old` → `rename old to <name>-prev-<old-sha>` → `run new`. Rollback is the
stopped `-prev-` container: start it and the previous image comes back with its
full environment intact. Never `docker run` a replacement by hand; the running
container's environment (often far too long to retype) exists nowhere else in
usable form, and a hand-rolled run drops most of it. Never prune stopped containers or
untagged images on this box; they are the rollback targets.

## Guard 1: no-op

Same image tag AND no environment delta: refuse, nothing to do. Fires only when
tags match, so it says nothing about a different tag.

## Guard 2: denylist against the incoming image

Grep the *incoming* image for names that must not reach production (retired
database names, retired hosts, dead secret paths). Refuse if any is reachable.
Inspects the incoming image only, so it cannot see what is running.

## Guard 3: image behind running

Refuse when the incoming tag names an ancestor of the running one. Explicit
`--rollback` overrides. Why the first two do not cover it: an environment-only
deploy was prepared naming the running tag; another agent shipped two commits
in the meantime; the unchanged command would have stopped production and
started the OLDER build, withdrawing a live signed log while reporting itself
as an environment change. Guard 1 missed it because the tags differed. Guard 2
passed because the older image was clean. This guard is also the only thing
that once caught production serving a commit that existed on no remote branch.

## Guard 4: migration ledger versus the image

Before any restart of a service that applies migrations at boot: compare the
database's applied-migration head with the newest migration file inside the
running image. If the ledger is ahead of the image (someone applied migrations
by hand, or a newer image applied them and was then rolled back), a restart
crash-loops on "version missing" and the service stays dark under
`unless-stopped`. Make it part of your swap tooling, and run it by hand before
any restart you do outside that tooling.

## The collision that leaves a 502

The rename step fails if `<name>-prev-<old-sha>` already exists, which happens
on any redeploy of an already-deployed SHA. Without collision handling the
script aborts *after* the stop and *before* the run: nothing listening, edge
returns 502. The dry run prints the rename without checking the name. Fix in
the script: check for the collision before the stop, or suffix the prev name
with a timestamp. Recovery in the meantime: start the stopped container.

A public 502 is not automatically this failure. On 2026-10-05/06,
`radiolan.live/hub` returned Cloudflare `error code: 502` on about a third of
requests while Caddy on the box logged only 200s: a second `cloudflared`
connector (a forgotten Mac LaunchDaemon) had no origin. Prove origin vs edge
before you restart a container. See the top-level README recovery table.

## Migration numbering

Two agents will eventually give two migrations the same number. If the
migration tool keys by version, the second can never apply and its feature
ships non-functional with no error. A CI check per PR cannot see a merge race:
the collision recurred on 2026-09-22, when two PRs merged about ten seconds
apart, each clean against its own base. Refuse duplicate versions at deploy
time, and run `ls migrations | sed 's/_.*//' | sort | uniq -d` against main
before every ship.
