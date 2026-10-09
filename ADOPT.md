# Adopting the kit

One evening per step. Each step stands alone; stop wherever you like.

0. **Run `./test.sh`.** Everything below is exercised by it. If it does not
   say `RESULT: all passed` on your machine, stop and read why.

1. **Hooks.** Copy `kit/hooks/` into your repo at the same path, `kit/hooks/`,
   together with a gate script (`ops/local-ci.sh`; start from `kit/ops/local-ci.sh`)
   and `ops/gate-record.sh` (from `kit/ops/gate-record.sh`). The gate prints one
   line, `RESULT: <passed> passed, <failed> failed, <skipped> skipped`. If your
   default branch is not `main`, set `KIT_GATE_BASE` (for example `origin/master`)
   for the gate; with no usable base it says so and runs every job rather than
   check less. A push that carries nothing the remote lacks (a new branch or tag at
   a commit it already has) is not gated and needs no override. Commit all
   of it on a branch and merge it, so that the shared checkout and every worktree
   receive the hooks: a worktree only has what is committed. Then, in each clone
   and worktree, run `kit/hooks/install-githooks.sh` (it refuses to replace an
   existing `core.hooksPath` or active hooks in `.git/hooks`; `KIT_FORCE_HOOKS=1`
   overrides, after you have looked). Tell the hook where the shared checkout
   is: run `git config kit.shared-tree /path/to/shared/checkout` inside the shared
   checkout itself (worktrees share its config), or export `KIT_SHARED_TREE_PATH`.
   Verify from a branch that is not main: a commit in the shared checkout must be
   refused with the "shared canonical checkout" text. A commit refused only
   because you are on main proves nothing. Until the gate exists the pre-push
   hook logs SKIPPED on every push and records the commit as not gated. It also
   refuses a push from a tree that is not clean, untracked files included, so
   put build output in `.gitignore`.

   The hooks run from whichever commit is checked out, because the path is
   relative: a branch you check out brings its own `kit/hooks/`. In a clone that
   has run the installer, do not check out a branch you do not trust; use
   `git -c core.hooksPath=/dev/null checkout <branch>`, or a clone that has not
   run the installer. The fast-forward timer below runs git without hooks.

2. **Fast-forward timer.** Install the script and the units:

       install -Dm0755 kit/timers/ff-only.sh ~/.local/bin/ff-only.sh
       mkdir -p ~/.config/systemd/user
       cp kit/timers/ff-only.service kit/timers/ff-only.timer ~/.config/systemd/user/

   In the copied unit set `Environment=KIT_FF_TREE=/path/to/shared/checkout` (the
   default `$HOME/app` is almost certainly not yours), add
   `Environment=KIT_FF_BRANCH=<your default branch>` if it is not `main`, and set
   `ExecStart` to where you installed the script. `--self-test` proves the script,
   not your configuration, so also run
   `KIT_FF_TREE=/path/to/shared/checkout ~/.local/bin/ff-only.sh --dry-run` once by
   hand. Then `systemctl --user enable --now ff-only.timer`. On a headless box a
   user timer stops when you log out unless lingering is on (`loginctl
   enable-linger <you>`, which needs root; make that change deliberately). Read
   `~/.local/state/ff-only.log` the next day. A line is NOOP, FF, WOULD_FF (the
   dry run), REFUSE with a reason, or FAIL with git's reason; for anything else,
   `journalctl --user -u ff-only`. An untracked file in the shared checkout that
   the fast-forward would overwrite makes it FAIL, and the dry run cannot see that,
   so make changes in a worktree, never in the shared checkout.

3. **Agent roles.** Copy `kit/agents/` into your runner's definitions directory
   (Claude Code: `~/.claude/agents/`) and replace the `<your ... model>`
   placeholders with real model names. The roles only help if the driver session
   is told to delegate lookups to `scout` and claims to `verify`: say so in your
   standing instructions (step 4).

4. **Rules.** Adopt `kit/rules/` as standing instructions: for Claude Code, copy
   the three files into `~/.claude/rules/` or paste them into your project's
   `CLAUDE.md`; other runners have their own instructions file. The
   secret-handling rule is the one you will be glad of first. Rule 03 names the
   status board and the machine briefing, which step 6 creates: until it does,
   delete those sentences rather than leave the rule pointing at nothing.

5. **Memory.** `kit/memory/CONVENTION.md` is the convention, `TEMPLATE.md` is one
   entry, and `EXAMPLE-hub.md` and `EXAMPLE-index.md` show how old threads fold
   and what the loaded index looks like. Keep the store outside any repository you
   publish, and have your runner load the index into each session. The first
   useful entry is the first thing an agent got wrong twice.

6. **Status board and briefing.** `install -Dm0755 kit/ops/status-board.py
   ~/.local/bin/status-board.py`, then run it once by hand with your `KIT_*`
   variables set (see `kit/ops/status-board.md`); it writes
   `~/.config/kit/status.json`, or `KIT_STATUS_OUT`. Point `KIT_HEALTH_URLS` at
   the **public** hostname, not only loopback Caddy: origin 200 is not edge
   200. Probe with curl; a Python client can get Cloudflare 1010 and that is
   not an origin failure. Schedule the board every five
   minutes with a user timer shaped like the fast-forward one (copy
   `kit/timers/ff-only.service` and `.timer`, change `Description`, `ExecStart`
   and `OnUnitActiveSec=5min`), and name its path in rule 03 so agents read it
   first. Then write the machine briefing from `kit/ops/briefing-template.md`:
   hazards and verify commands only, including tunnel connector count (one
   connector is usually 4 edge connections; 8 means two) and which paths are
   static files vs an API unit.

7. **Watchdog, backup health, honesty marker.** Only if the box serves
   production. Read the three docs in `kit/ops/`; each one is a recipe plus the
   incident that made it. The watchdog files in `kit/ops/watchdog/` are drafts to
   read and install by hand, with root, one at a time (`watchdog.md` first).
   Backup health: pipe your bucket listing, one `<key>`, `<size>`, `<modified>`
   row per line separated by tabs, into `kit/ops/backup-health.py` from a
   read-only timer, and page on exit 1 or 2. The honesty marker needs `gh`,
   `KIT_GATE_REPO=owner/repo`, `gate-record.sh`, `gate-attest.sh`,
   `premerge-check.sh` and `marker-parse.awk` copied together into your repo's
   `ops/` directory, and one session id per agent (`premerge-check.sh <pr> --as
   <your-session-id>`).

8. **Leak gate.** Before you publish anything from this tree, build your own list
   at `~/.config/battleship-kit/denylist.txt` (private repo names, hostnames,
   buckets, people; never commit it). `./scan.sh` refuses to run without it unless
   you set `KIT_ALLOW_GENERIC_ONLY=1`, which checks the generic shapes only and
   says so. Run `./scan.sh && ./scan.sh --history`, build a snapshot with
   `./export-public.sh --identity "<Name> <your GitHub noreply address>" <new-dir>`,
   publish the snapshot rather than the repo with the one command it prints, after setting `REPO=owner/name` (see
   `PUBLISHING.md`, including what the gate cannot see), and chain the publish on
   its exit code with `&&`. `scan.sh` and `export-public.sh` must sit at the
   repository root.

9. **Could your tests have failed?** Optional, and the step that taught this kit
   the most. `python3 kit/ops/mutate.py <script>:<sections> -- ./test.sh` changes
   one line of a script at a time (a comparison, `&&` for `||`, an `exit 1` for an
   `exit 0`, a deleted statement) in a scratch clone and reruns your tests. A
   mutant the tests survive is behaviour nothing checks: some survivors are
   harmless, the rest are the next bug. It is slow (each mutant reruns the named
   sections of your tests, stopping at the first failure, and a survivor runs them
   all), so aim it at one script at a time.
