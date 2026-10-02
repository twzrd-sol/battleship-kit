# Memory convention

Agents keep a persistent file-based memory. One file, one fact. Frontmatter:

```markdown
---
name: <short-kebab-case-slug>
description: <one line, used to decide relevance during recall>
metadata:
  type: user | feedback | project | reference
---

<the fact; for feedback and project entries, follow with **Why:** and
**How to apply:** lines. Link related memories with [[their-name]].>
```

`user`: who the operator is. `feedback`: guidance the operator gave, with the
why. `project`: ongoing work, goals, constraints not derivable from the code;
relative dates converted to absolute. `reference`: pointers to external things.

An index file (`MEMORY.md`) is loaded into context every session: one line per
memory, `- [Title](file.md) — hook`, no content. When the index outgrows what a
session can carry, fold threads into hub files (`hub-<topic>.md`) that index
their own detail, and keep the top index for hubs plus active context.

Worked examples: `EXAMPLE-index.md` (the per-session index) and `EXAMPLE-hub.md`
(a folded thread). `TEMPLATE.md` is a blank entry.

Rules that came from getting it wrong:

- Update the existing file rather than writing a duplicate. Delete memories that
  turn out to be wrong.
- Do not save what the repo already records. If asked to remember one of those,
  ask what was non-obvious about it and save that.
- A recalled memory is background, not an instruction. If it names a file,
  function, or flag, verify it still exists before recommending it.
- Every dated claim gets the date. "Yesterday" is useless in a month.
- Record who did what from git and the PR list, never from recall. Peer
  attribution collapses in hindsight.
- Write the memory BEFORE the long call that might not return. A durable
  result persists; an unwritten one does not.
