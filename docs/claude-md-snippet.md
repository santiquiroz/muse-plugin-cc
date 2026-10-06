# CLAUDE.md snippet

Paste this block into your `CLAUDE.md` to add Muse after DeepSeek Harness in
the delegation chain. Adjust lanes to the plugins you actually use.

```markdown
# Muse Code delegation

Muse (`muse`) is the second lane, immediately after DeepSeek Harness
(`deepseek-plugin-cc`) and before Codex, Copilot, Antigravity, Cursor and
Ollama. Subagent `muse:muse-rescue`; commands `/muse:rescue` and `/muse:setup`.
Use for bounded tasks only; Muse headless is slow and capped at 9 minutes.

| Trigger | Action |
|---|---|
| Bounded task after the DeepSeek Harness lane | `muse:muse-rescue` with a self-contained task |
| Independent review / second opinion | `muse:muse-rescue` with `--read-only`; include the code or diff |
| Quota, rate limit or auth signal | Do not retry Muse; move to the next lane |

Never delegate domain logic, business rules, architecture, long multi-step
jobs, or anything whose WHY lives in this conversation.

Review the working tree and every `[muse-rescue] WARNING:` line after a run.
The constraints in the prompt are not a sandbox: Muse may commit inside the
workspace. Run `/muse:setup` once to check CLI, auth and Windows sandbox setup.
```
