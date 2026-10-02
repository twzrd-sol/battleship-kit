# Secret handling

Standing rule for every agent lane.

1. Secret-manager output and container environment dumps never enter prompts,
   tickets, or committed files. When a check needs a secret, extract the single
   value into a shell variable, use it, and report only counts, booleans, or
   HTTP statuses. Never the value.
2. PR bodies, issue comments, and committed docs get SHAs, counts, and status
   codes. Never env dumps, DSNs, or tokens. An agent that needs to reference a
   secret names it, never prints it.
3. Full-auto approval bypasses stay out of serve and deploy scopes. Nothing
   unattended runs against production containers, the live database, or
   payment webhook management. That work runs attended, one verified step at a
   time.
4. MCP servers and agent tooling are version-pinned, never `@latest`. A
   floating tag is a supply-chain float with tool access. Bumps are deliberate,
   one package at a time, recorded where the pin lives.
5. A leak scan gates every publish: `./scan.sh && publish`, never
   `./scan.sh; publish`. The second form publishes on a hit.
