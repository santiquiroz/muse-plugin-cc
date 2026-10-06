# muse-plugin-cc

Delegate bounded coding tasks from [Claude Code](https://claude.com/claude-code)
to Muse Code's CLI (`muse`) in headless mode.

Claude Code remains the orchestrator: it supplies the task contract, handles
domain decisions and reviews the changes. Muse is the **second lane**, right
after [DeepSeek Harness](https://github.com/santiquiroz/deepseek-plugin-cc)
and before Codex, Copilot, Antigravity, Cursor and Ollama. Use it for a bounded
spec, rename, boilerplate task, one fix, focused investigation or read-only
second opinion—not long multi-step jobs. Muse is slow: a trivial three-step
task took about four minutes.

Sibling plugins include
[deepseek-plugin-cc](https://github.com/santiquiroz/deepseek-plugin-cc),
[copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc),
[antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc),
[cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) and
[ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc).
**Not affiliated with Meta, Anthropic, OpenAI, GitHub or the sibling projects.**

> Leer en español: [README.es.md](README.es.md)

## Delegation position

| Order | Lane | Good for |
|---|---|---|
| First | [DeepSeek Harness](https://github.com/santiquiroz/deepseek-plugin-cc) | Preferred first agentic lane |
| **Second (this plugin)** | **Muse Code** | Bounded tasks and read-only second opinions |
| Next | Codex, Copilot, Antigravity, Cursor, Ollama | Fallback when Muse is unavailable, rate-limited or unauthenticated |
| Keep inline | Claude Code | Domain logic, business rules, architecture and tasks whose WHY lives in the conversation |

Install only the lanes you use; this plugin works on its own.

## Requirements

- Claude Code; the forwarder runs through its Bash tool (Git Bash on Windows).
- Muse Code CLI. Verified facts in this plugin target Muse Code **1.4.3 on
  Windows 11**.
- Node.js on `PATH`; `scripts/stream-filter.js` requires `node`.
- Authentication via `muse login` or the `META_API_KEY` environment variable.

On Windows, the per-user install has `%LOCALAPPDATA%\Programs\muse\muse.cmd`;
the actual binary is next to it as `muse-bin-<version>.exe`. The forwarder
prefers the version named by `.muse-version`, then the newest matching binary,
then `muse` on `PATH` on macOS/Linux. `MUSE_BIN` overrides launcher selection
(also used by the tests).

## Install

In Claude Code:

```text
/plugin marketplace add santiquiroz/muse-plugin-cc
/plugin install muse@muse-plugin-cc
```

Then, once per machine:

```text
/muse:setup
```

If needed, sign in with `muse login` in a normal terminal. On Windows, setup
also requires `muse sandbox windows setup` from an elevated terminal. The
plugin's setup command checks these preconditions without printing credentials.

## Usage

```text
/muse:rescue add unit tests for src/utils/money.ts covering rounding and negative amounts
/muse:rescue --read-only review this pasted diff for race conditions: <diff>
/muse:rescue --model muse-spark-1.3-contributor --reasoning-effort high diagnose this focused build failure
/muse:rescue --max-model-steps 30 implement the single acceptance criterion below
```

Put flags before the task text. Supported runtime flags:

- `--model <slug>` — optional; if omitted Muse uses the account's default
  model. Slugs are validated before invocation.
- `--reasoning-effort <tier>` — one of `none`, `minimal`, `low`, `medium`,
  `high`, `xhigh`, `max`, or `ultra`. If omitted Muse uses its default.
- `--max-model-steps <N>` — positive integer; default 60.
- `--read-only` — adds `--disable-write --disable-shell` and a read-only task
  constraint. Paste code or a diff to review; the delegate cannot run shell
  commands or inspect files.

There is no `--continue` in this release; exec session resume is unverified.
Every run is capped at 9 minutes (`MUSE_RESCUE_TIMEOUT` can override the
seconds). Muse headless runs can be slow; interrupted or timed-out edits stay
in the working tree. The forwarder passes the task and constraints in a
temporary `--prompt-file`, not in the process argument list.

## What the forwarder runs

The `muse-rescue` subagent uses one foreground preflight call and, only if it
succeeds, one foreground run call. It creates a prompt file containing the
request and its constraints, then runs the equivalent of:

```bash
muse exec --json --prompt-file <native temporary path> \
  --workspace <native current directory> \
  --approval-mode never --approval-judge off --no-foreign-personal-context \
  --user-input-auto-resolve --max-model-steps 60 \
  [--model <slug>] [--reasoning-effort <tier>]
```

`--no-foreign-personal-context` is mandatory: without it Muse may load the
caller's personal Claude Code instructions and skills, inviting recursive
delegation. The child gets `GIT_TERMINAL_PROMPT=0`,
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, no MSYS path-conversion overrides,
and closed stdin. Paths are converted with `cygpath -w` when available.

The JSONL filter prints progress and the terminal answer once, suppresses
streamed answer deltas, and reports tool failures and retries. The summary
includes elapsed time, session ID and configured model when provided by Muse.
Exit statuses pass through; timeout statuses `124`, `137` and `142` also get
an explicit timeout message.

## Safety model

The default behavior relies on **Muse's own OS sandbox**, which confines
writes to the workspace. Its default sandbox network is limited to Muse's
proxy (`--sandbox-network proxy-only`); the forwarder does not disable the
sandbox or enable network access. `--approval-mode never` and
`--approval-judge off` mean nothing is auto-approved or prompted. A denied
write outside the workspace fails closed. `--read-only` additionally disables
both writes and shell tools.

The prompt's constraints are not a sandbox: the delegate can still commit
inside the workspace. Before and after the run, the forwarder compares `HEAD`,
branch, stash, git config and hooks and prints a `[muse-rescue] WARNING:` for
changes. Review every warning and the working tree before your next git
command. The forwarder refuses `--yolo`, `--disable-sandbox`,
`--disable-approval`, `--trust-workspace`, and
`--sandbox-network enabled`; unknown options fail with exit 64.

**Windows AppData trap:** Muse's sandbox shell hangs without an error when the
workspace is private to the signed-in user, such as under
`%USERPROFILE%\AppData\Local\Temp`. File tools may still work. Use a repo
outside the profile, in a folder readable by Authenticated Users. The
forwarder prints a warning for workspaces under the profile's AppData and
continues the run.

### Authentication and Windows sandbox preflight

`META_API_KEY` takes priority. Otherwise setup checks
`~/.config/muse/auth.json` for a `meta` provider with a non-empty
`access_token` or `api_key` without printing that file. If neither exists,
preflight exits 70 and instructs you to run `muse login` once in a normal
terminal, then `/muse:setup`.

On Windows, `muse sandbox windows check` must report `status=ready`.
Otherwise preflight exits 78 and asks you to run
`muse sandbox windows setup` from an elevated terminal. This check is skipped
on non-Windows hosts.

## Files and tests

| Path | Purpose |
|---|---|
| `agents/muse-rescue.md` | Thin Bash-only forwarder subagent |
| `scripts/muse-forward.sh` | Launcher, preflight, safe invocation, timeout and git warnings |
| `scripts/stream-filter.js` | Muse JSONL to compact progress and final response |
| `tests/run.sh` | Hermetic test suite using a fake Muse CLI |
| `/muse:rescue`, `/muse:setup` | Delegation and preflight commands |
| `docs/delegation-guide.md` | Lane positioning, safety and fallback |
| `docs/claude-md-snippet.md` | Ready-to-paste delegation guidance |

The test suite is `bash tests/run.sh`. CI runs it on Ubuntu and Windows.

## Not yet

- `--continue` / session resume; Muse exec session resume is unverified.
- A quota meter; Muse's basic subscription does not expose a headless usage
  meter. On quota or rate-limit output, stop and fall back—never retry.

## License

[MIT](LICENSE)
