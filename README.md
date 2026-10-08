# muse-plugin-cc

Delegate bounded coding tasks from [Claude Code](https://claude.com/claude-code)
to Muse Code's CLI (`muse`) in headless mode.

Claude Code remains the orchestrator: it supplies the task contract, handles
domain decisions and reviews the changes. Use this plugin for a bounded spec,
rename, boilerplate task, one fix, focused investigation or read-only second
opinion. Muse is slow: a trivial three-step task took about four minutes.

> Leer en español: [README.es.md](README.es.md)

## When it helps

- **Flat-rate subscription:** delegated runs bill to your Muse subscription,
  so offloading bounded work adds no per-call cost.
- **Bounded tasks:** a spec, rename, boilerplate, one fix or a focused
  investigation — work with a clear contract that does not need the
  conversation's context.
- **Read-only second opinions:** `--read-only` reviews pasted code or a diff
  without touching files or running shell commands.
- **Long decoupled runs:** jobs detach and run up to 45 minutes by default
  while you keep working; an interrupted wait can resume later with the job id.
- **Honest cost:** Muse is slow. Keep delegated tasks self-contained and do
  not wait on it for quick answers.

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

## Setup

Once per machine:

```text
/muse:setup
```

If needed, sign in with `muse login` in a normal terminal. On Windows, setup
also requires `muse sandbox windows setup` from an elevated terminal. The
plugin's setup command checks these preconditions without printing credentials.

## Usage

```text
/muse:rescue --background add unit tests for src/utils/money.ts covering rounding and negative amounts
/muse:rescue --read-only review this pasted diff for race conditions: <diff>
/muse:rescue --model muse-spark-1.3-contributor --reasoning-effort high diagnose this focused build failure
/muse:rescue --max-model-steps 30 implement the single acceptance criterion below
```

`/muse:rescue` invokes the `muse-rescue` subagent automatically, forwarding the
raw request as its prompt and returning its output verbatim, including any
`[muse-rescue] WARNING:` lines. Put flags before the task text. Supported flags:

- `--wait` — default; run the subagent in the foreground. It awaits a
  detached Muse job through repeated `wait` slices. An interrupted subagent
  leaves the job running; retain its id to `wait` or `cancel` later.
- `--background` — run the subagent in the background and relay its output
  when it completes. These execution flags are removed from the task before
  forwarding; the forwarder's Bash calls remain foreground.
- `--model <slug>` — optional; if omitted Muse uses the account's default
  model. Slugs are validated before invocation.
- `--reasoning-effort <tier>` — one of `none`, `minimal`, `low`, `medium`,
  `high`, `xhigh`, `max`, or `ultra`. If omitted Muse uses its default.
- `--max-model-steps <N>` — positive integer; default 60.
- `--read-only` — adds `--disable-write --disable-shell` and a read-only task
  constraint. Paste code or a diff to review; the delegate cannot run shell
  commands or inspect files.

There is no `--continue` in this release; exec session resume is unverified.

### Long runs

Runs last up to `MUSE_RESCUE_MAX_SECONDS` (default 2700 seconds, 45 minutes).
`start` detaches the job and `wait <id>` awaits it in 480-second slices
(`--slice <seconds>` accepts up to 540). Each is a separate foreground Bash
call with timeout 600000 ms; exit 75 means still running. The call budget is
`1 + 1 + ceil(MAX/480) + 1`. If the subagent is interrupted, the job continues:
retain its started id to `wait <id>` or `cancel <id>` later. Cancellation exits
130; a wait past the deadline kills the process tree and exits 124. Edits
remain in the working tree. The `run` command keeps a short default limit of 540 seconds
(`MUSE_RESCUE_TIMEOUT` overrides the seconds). The forwarder passes the task
and constraints in a temporary `--prompt-file`, not in the process argument list.

### What the forwarder runs

The `muse-rescue` subagent uses foreground `preflight`, then `start`, then
repeated `wait <id>` calls while exit 75 reports a running job. The script
detaches Muse with `nohup`, background and `disown`; job files live under
`${MUSE_RESCUE_HOME:-$HOME/.muse-rescue}/jobs/<id>/`. It creates a prompt file
containing the request and its constraints, then runs the equivalent of:

```bash
muse exec --json --prompt-file <native temporary path> \
  --workspace <native current directory> \
  --approval-mode never --approval-judge off --no-foreign-personal-context \
  --user-input-auto-resolve --max-model-steps 60 \
  [--model <slug>] [--reasoning-effort <tier>]
```

`--read-only` additionally passes `--disable-write --disable-shell`. The child
gets `GIT_TERMINAL_PROMPT=0`,
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, no MSYS path-conversion overrides,
and closed stdin. Paths are converted with `cygpath -w` when available.

The JSONL filter prints progress and the terminal answer once, suppresses
streamed answer deltas, and reports tool failures and retries. The summary
includes elapsed time, session ID and configured model when provided by Muse.
Exit statuses pass through; deadline expiry reports an explicit timeout
message and exits 124. Each wait prints only new progress.

## Safety model

The default behavior relies on **Muse's own OS sandbox**, which confines
writes to the workspace. Its default sandbox network is limited to Muse's
proxy (`--sandbox-network proxy-only`); the forwarder does not disable the
sandbox or enable network access. `--approval-mode never` and
`--approval-judge off` mean nothing is auto-approved or prompted. A denied
write outside the workspace fails closed. `--read-only` additionally disables
both writes and shell tools.

`--no-foreign-personal-context` is mandatory: without it Muse may load the
caller's personal Claude Code instructions and skills, inviting recursive
delegation.

The task constraints forbid committing, pushing, resetting, checking out,
cleaning, switching branches and deleting files — but the prompt's constraints
are not a sandbox: the delegate can still commit inside the workspace. Before
and after the run, the forwarder compares `HEAD`, branch, stash, git config
and hooks and prints a `[muse-rescue] WARNING:` for changes. Review every
warning and the working tree diff before your next git command. The forwarder
refuses `--yolo`, `--disable-sandbox`, `--disable-approval`,
`--trust-workspace`, and `--sandbox-network enabled`; unknown options fail
with exit 64.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `MUSE_BIN` | launcher discovery | Overrides Muse launcher selection (also used by the tests) |
| `META_API_KEY` | none | Authentication; takes priority over the auth file |
| `MUSE_RESCUE_HOME` | `$HOME/.muse-rescue` | Job files live under `jobs/<id>/` |
| `MUSE_RESCUE_MAX_SECONDS` | `2700` (45 minutes) | Detached-run deadline for `start`/`wait` |
| `MUSE_RESCUE_TIMEOUT` | `540` | Short `run` command limit, in seconds |
| `MUSE_RESCUE_PS` | `powershell.exe` | Process-inventory command for orphan cleanup (hermetic tests) |
| `MUSE_RESCUE_KILL` | `taskkill` | Process-tree kill command (hermetic tests) |
| `MUSE_RESCUE_FORCE_WINDOWS` | `0` | Treat the host as Windows (tests) |

## Troubleshooting

- **No credentials (exit 70):** `META_API_KEY` takes priority. Otherwise setup
  checks `~/.config/muse/auth.json` for a `meta` provider with a non-empty
  `access_token` or `api_key` without printing that file. If neither exists,
  run `muse login` once in a normal terminal, then `/muse:setup`.
- **Windows sandbox not ready (exit 78):** `muse sandbox windows check` must
  report `status=ready`. Otherwise run `muse sandbox windows setup` from an
  elevated terminal. This check is skipped on non-Windows hosts.
- **Missing CLI or Node (exit 127):** install Muse Code or ensure `muse` is
  on `PATH`; install Node.js and ensure `node` is on `PATH` for the JSONL
  filter. On Windows, the per-user install's `muse.cmd` is a launcher; this
  plugin prefers the versioned binary beside it. `MUSE_BIN` overrides launcher
  selection. Run `/muse:setup` again.
- **AppData workspace hang:** Muse's sandbox shell hangs without an error when
  the workspace is private to the signed-in user, such as under
  `%USERPROFILE%\AppData\Local\Temp`. File tools may still work. Use a repo
  outside the profile, in a folder readable by Authenticated Users. The
  forwarder prints a warning for workspaces under the profile's AppData and
  continues the run.
- **Orphan sandbox workers:** on Windows, deadline, cancellation and the short
  `run` timeout kill the entire process tree with `taskkill /T /F /PID` while
  the parent is alive. Muse sandbox workers otherwise remain orphaned and hold
  the global `Global\TbhWindowsSandboxAclPublication` lock, causing later runs
  to fail after 120 seconds with an ACL publication lock timeout. Windows
  preflight checks sandbox worker command lines and parent process IDs, then
  kills only workers whose parent no longer exists. It prints
  `[muse-rescue] killed N orphan Muse sandbox worker(s) left by an interrupted run`.
  Workers belonging to a live interactive Muse session remain untouched.
- **Git `dubious ownership`:** every child receives workspace `safe.directory`
  via `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_N` and `GIT_CONFIG_VALUE_N`, using
  forward slashes. The entry appends to existing config entries and leaves
  global git config untouched. This lets Muse's different Windows sandbox user
  run git in the workspace without a `detected dubious ownership` failure.
- **Quota or rate limit:** on output mentioning `rate limit`, `429`, `quota`,
  `usage limit`, `limit reached` or `insufficient`, stop and report it so the
  caller can choose another route; never retry Muse. Muse's basic subscription
  does not expose a headless usage meter. On `401`, `unauthorized` or `login`
  output, run `muse login` in a normal terminal, then `/muse:setup`.
- **Interrupted subagent:** an interrupted subagent leaves the detached job
  running. Retain its started id to `wait <id>` or `cancel <id>` later.
  Cancellation exits 130; a wait past the deadline kills the process tree and
  exits 124. Edits remain in the working tree.
- **Session resume:** this release has no `--continue`; exec session resume is
  unverified.

## Using it with other delegates

If you use several delegation plugins, decide their order in your `CLAUDE.md`;
this plugin assumes none. On quota, rate-limit or authentication signals it
stops and reports, so the caller can choose another route.

Related projects: [deepseek-plugin-cc](https://github.com/santiquiroz/deepseek-plugin-cc), [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc), [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc), [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc), [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc).

## Files and tests

| Path | Purpose |
|---|---|
| `agents/muse-rescue.md` | Thin Bash-only forwarder subagent |
| `scripts/muse-forward.sh` | Launcher, preflight, safe invocation, timeout and git warnings |
| `scripts/stream-filter.js` | Muse JSONL to compact progress and final response |
| `tests/run.sh` | Hermetic test suite using a fake Muse CLI |
| `/muse:rescue`, `/muse:setup` | Delegation and preflight commands |
| `docs/delegation-guide.md` | Delegation safety and fallback |
| `docs/claude-md-snippet.md` | Ready-to-paste delegation guidance |

The test suite is `bash tests/run.sh`. CI runs it on Ubuntu and Windows.

## License

[MIT](LICENSE)

**Not affiliated with Meta or Anthropic.**
