---
description: Delegate a bounded coding task to Muse Code through the muse-rescue subagent
argument-hint: "[--model <slug>] [--reasoning-effort <tier>] [--max-model-steps <N>] [--read-only] [the task Muse should perform]"
allowed-tools: Agent
---

Invoke the `muse:muse-rescue` subagent using the Agent tool, forwarding the raw
user request as its prompt. It is a subagent, not a skill. Return its final
output verbatim, including any `[muse-rescue] WARNING:` lines.

Muse is the second lane after DeepSeek Harness and is for bounded tasks only.
Do not dispatch long multi-step jobs. For read-only reviews, ask the user to
include the relevant code or diff in the task.

If the result starts with `[muse-rescue] Muse quota or rate limit hit`, do not
retry Muse; fall back to the next lane or handle inline. If authentication is
missing, tell the user to run `muse login` in a normal terminal and then
`/muse:setup`. If no task was supplied, ask what Muse should do.

Raw user request:
$ARGUMENTS
