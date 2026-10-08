---
description: Delegate a bounded coding task to Muse Code through the muse-rescue subagent
argument-hint: "[--background|--wait] [--model <slug>] [--reasoning-effort <tier>] [--max-model-steps <N>] [--read-only] [the task Muse should perform]"
allowed-tools: Agent
---

Invoke the `muse:muse-rescue` subagent using the Agent tool, forwarding the raw
user request as its prompt. It is a subagent, not a skill. Return its final
output verbatim, including any `[muse-rescue] WARNING:` lines.

Execution mode:

- If the request includes `--background`, run the subagent in the background
  and continue other work; relay the result when it completes.
- If the request includes `--wait`, run the subagent in the foreground.
- If neither flag is present, default to foreground.
- `--background` and `--wait` control the Agent invocation. Remove them from
  the forwarded prompt; they are not runtime flags or task text.
- Preserve `--model`, `--reasoning-effort`, `--max-model-steps` and `--read-only`
  in the forwarded prompt. The subagent extracts them before forwarding the
  natural-language task.

Forward a self-contained task. For read-only reviews, ask the user to
include the relevant code or diff in the task.

The subagent calls `preflight`, then `start`, then repeats `wait <id>` while
it exits 75. Each is a separate foreground Bash call; waits use timeout
600000 ms, never `run_in_background`. The forwarder detaches Muse. Runs last
up to `MUSE_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes), awaited in
480-second slices (maximum 540). The call budget is
`1 + 1 + ceil(MAX/480) + 1`.

If the subagent is interrupted, retain its started job id: the job keeps
running. Later use `bash "${CLAUDE_PLUGIN_ROOT}/scripts/muse-forward.sh" wait <id>`
or `cancel <id>` (exit 130). A wait past the deadline kills the process tree
with exit 124. Edits remain in the working tree.

If the result starts with `[muse-rescue] Muse quota or rate limit hit`, do not
retry Muse; report it to the user so they can choose another route, or handle
the task inline. If authentication is missing, tell the user to run
`muse login` in a normal terminal and then `/muse:setup`. If no task was
supplied, ask what Muse should do.

Raw user request:
$ARGUMENTS
