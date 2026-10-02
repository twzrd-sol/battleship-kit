# Agent definitions

Three roles, each with a model pin and a tool-call cap written into its prompt. `scout`
and `verify` list Read, Grep, Glob and Bash and are told in their prompts to stay read-only;
Bash can still write, so that is a rule, not a restriction. `verify` needs Bash to re-run
commands. `worker` inherits every tool. The harness does not enforce the cap: the agent is
told to stop and report against it.
Drop them in your agent runner's definitions directory (for Claude Code:
`~/.claude/agents/`). Fill in the model names; the point is the *tiering*:
the cheap model looks things up, the mid model checks claims, the strong model
builds. The driver session should not do any of the three itself when it can
delegate.

The tiering began as a cost control. The cap earns its keep as a truthfulness
control: an agent that runs out of budget must say what it did not finish,
instead of narrating around it.

`verify` exists because a report from an agent is a claim, not evidence. Every
number in a status report was produced by some command; `verify` runs it again.
