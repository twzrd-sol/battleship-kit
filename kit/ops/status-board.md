# Status board

Generator: `status-board.py` in this directory (env: `KIT_STATUS_OUT`,
`KIT_SHARED_TREE_PATH`, `KIT_HEALTH_URLS`, `KIT_PROD_CONTAINERS`). Only
CONFIGURED checks produce a color: every health URL must return 200, and every
container named in `KIT_PROD_CONTAINERS` must be running and not unhealthy (no
healthcheck counts as up; not running is red). If nothing is configured, or a
configured check cannot be run (docker failing), the color is `unknown`, never
`green`.

A read-only JSON file the machine writes about itself every few minutes from a
user-scope timer. Agents read it before touching anything. It contains what the
generator emits: `generated_at` and `valid_for_seconds`; `gate_color` with its
inputs; `host` (kernel, uptime, load, memory, disk); `containers` (one row per
configured container, with its state); `shared_git` (branch, head, origin/main,
tracked_dirty, worktree count, the last fast-forward log line); `timers` (the
number of rows `systemctl --user list-timers --all` prints, enabled or not; null
with a section error when systemctl cannot run); `health` (one row per configured URL); `backup`, a stub that reports
null until you wire a read-only bucket listing (see `backup-health.md`); and
`section_errors`. There is no GPU field; add one if you need it.

A reader treats a board older than `valid_for_seconds` as unknown, whatever its
color says. After any reboot compare `generated_at` with the clock: a timer that
elapsed during boot once left a board 28 hours stale while it still read green.

Rules:

- No secrets, no secret-manager calls, no wallet material. If a database URL
  must be parsed, keep only the database name.
- `gate_color` means *live health* (production is up), not "main is passing".
  Two different questions; name them differently.
- The board does not mutate anything except its own file.
- Every number on the board is something a human could re-derive with one
  command; the board's source says which command.
