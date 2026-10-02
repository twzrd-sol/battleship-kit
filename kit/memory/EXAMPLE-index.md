# MEMORY.md (example index)

This file is loaded into every session. One line per memory. No content here.
Keep the top section for active context; fold settled threads into hubs.

- [Deploy guards](deploy-guards.md) — no-op / denylist / image-behind-running; check ledger vs image before restart
- [Merged and green is not verified](merged-green-not-verified.md) — a deployed fix was inert on stored rows; read one artifact after every deploy
- [Process match kills your own shell](process-match-self-kill.md) — `pkill -f` matches the invoking shell; stop by PID

## Hubs (detail inside)
- [Ship log](hub-ship-log.md) — every deploy with its rollback name
- [Incidents and lessons](hub-incidents.md) — dated, with the rule each produced
- [History and superseded](hub-history.md) — settled cutovers; rules that now live in the briefing

## Active context
- [Quarter focus](quarter-focus.md) — one product line until the first paying user; decline the rest
- [Release freeze](release-freeze.md) — no publishes until the checklist passes; drafts stay private
