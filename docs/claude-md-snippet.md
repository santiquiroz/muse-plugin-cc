# CLAUDE.md snippet

Paste this block into your `CLAUDE.md` to add Muse after DeepSeek Harness in
the delegation chain. Adjust lanes to the plugins you actually use.

```markdown
# Muse Code delegation

Muse (`muse`) is the second lane, immediately after DeepSeek Harness
(`deepseek-plugin-cc`) and before Codex, Copilot, Antigravity, Cursor and
Ollama. Subagent `muse:muse-rescue`; commands `/muse:rescue` and `/muse:setup`.
Use self-contained tasks; Muse headless is slow. Detached runs last up to
45 minutes by default (`MUSE_RESCUE_MAX_SECONDS=2700`). The subagent starts
a detached job and repeats separate foreground `wait <id>` calls in
480-second slices (maximum 540); exit 75 means still running. Retain the id
if interrupted: the job continues and can be awaited or cancelled later.
`cancel <id>` kills the tree with exit 130; a wait past the deadline exits 124.

| Trigger | Action |
|---|---|
| Bounded task after the DeepSeek Harness lane | `muse:muse-rescue` with a self-contained task |
| Independent review / second opinion | `muse:muse-rescue` with `--read-only`; include the code or diff |
| Quota, rate limit or auth signal | Do not retry Muse; move to the next lane |

Never delegate domain logic, business rules, architecture, or anything whose
WHY lives in this conversation.

Review the working tree and every `[muse-rescue] WARNING:` line after a run.
The constraints in the prompt are not a sandbox: Muse may commit inside the
workspace. Run `/muse:setup` once to check CLI, auth and Windows sandbox setup.
```
