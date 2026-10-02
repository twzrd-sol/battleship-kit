# First read

Before touching code or services, read the machine's status board (a
read-only JSON the box writes about itself every few minutes; see
`kit/ops/status-board.md`). Then read the machine briefing (the one file that
lists standing hazards and the commands that verify them). The board carries its own
validity window: a board older than `valid_for_seconds` is unknown, whatever its color
says. After any reboot compare `generated_at` with the clock before trusting it.

The shared checkout is fast-forward-only when clean; feature work happens in
named worktrees only.

Runtime memories the agents keep for themselves are scratch, not canon. Canon
lives in the repo, under version control, with an owner and a review date.

Rules for the briefing file itself: it holds hazards and verify commands, not
history. History lives in git and in dated ops-history files. Never pin an
image digest or a commit SHA in the briefing; they rot within hours. Give the
command that reads the live value instead.
