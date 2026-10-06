# First read

Before touching code or services, read the machine's status board (a
read-only JSON the box writes about itself every few minutes; see
`kit/ops/status-board.md`). Then read the machine briefing (the one file that
lists standing hazards and the commands that verify them). The board carries its own
validity window: a board older than `valid_for_seconds` is unknown, whatever its color
says. After any reboot compare `generated_at` with the clock before trusting it.

Then prove the public path with curl, not a Python HTTP client (Cloudflare
error 1010 is a browser integrity check, not an origin failure). If the public
hostname is 502 and loopback Caddy is 200, the fault is the tunnel: count
connectors (`cloudflared tunnel info <tunnel-uuid> --config /dev/null`). One
connector is usually 4 edge connections; 8 means two. If static `/hub` is 200
and `/hub/api` is not, the station moved, not the site.

The shared checkout is fast-forward-only when clean; feature work happens in
named worktrees only. Do not prune worktrees by count: check each one for
dirty files, open PRs, and running processes, and record recovery commits
first.

Runtime memories the agents keep for themselves are scratch, not canon. Canon
lives in the repo, under version control, with an owner and a review date.

Rules for the briefing file itself: it holds hazards and verify commands, not
history. History lives in git and in dated ops-history files. Never pin an
image digest or a commit SHA in the briefing; they rot within hours. Give the
command that reads the live value instead.
