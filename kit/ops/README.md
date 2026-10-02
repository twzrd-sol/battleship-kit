# kit/ops

| File | Kind | Pairs with |
|---|---|---|
| `status-board.md`, `status-board.py` | doc + script | `kit/rules/03-first-read.md` |
| `briefing-template.md` | template | the first-read rule |
| `local-ci.sh` | script | a minimal gate honoring the RESULT contract; copy and add jobs |
| `honesty-marker.md`, `gate-record.sh`, `gate-attest.sh`, `premerge-check.sh`, `marker-parse.awk` | doc + scripts | `kit/hooks/pre-push` |
| `watchdog.md`, `watchdog/` | doc + units | a box that does risky things while serving |
| `backup-health.md`, `backup-health.py` | doc + script | any nightly dump |
| `deploy-guards.md` | doc | any container swap on a serving box |
| `mutate.py` | script | any test suite you want to doubt: it changes one line at a time and reports the changes your tests did not notice |

Every script here is exercised by `../../test.sh` without network, GitHub, or
Docker: `gate-attest.sh` and `premerge-check.sh` against a fake `gh`,
`status-board.py` against a fake `docker` and `curl`.
