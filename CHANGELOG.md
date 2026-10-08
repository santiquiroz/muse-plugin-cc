# Changelog

## 0.2.2 — 2026-10-07

- Add `-C <dir>` / `--cwd <dir>` to `preflight`, `run` and `start`: run Muse in another directory, such as a git worktree, instead of the caller's current one (whose sandbox grants no write access to the worktree, so every edit failed with Access denied). The home directory, its ancestors and agent config folders are refused.

## 0.2.1 — 2026-10-07

- Fix: `preflight` failed with exit 1 whenever a running process's command
  line contained a control character — Windows PowerShell 5.1's
  `ConvertTo-Json` leaves some of them unescaped and the orphan cleanup's
  `JSON.parse` threw. Control characters are now replaced before parsing, and
  an unreadable process list only skips the cleanup with a warning.
- Docs stand on their own, without a multi-lane setup: both READMEs rewritten
  (When it helps, Configuration, Troubleshooting and Using it with other
  delegates sections); the subagent description, `docs/` and
  `commands/rescue.md` no longer speak of lanes or rank other plugins.

## 0.2.0 — 2026-10-06

- Detached `start`, sliced `wait` (exit 75 while running) and `cancel`
  (exit 130); default deadline 2700 seconds via `MUSE_RESCUE_MAX_SECONDS`.
- Subagent repeats 480-second waits; `run` remains the short path with a default 540-second limit.
- Windows deadline, cancel and short-run timeout kill the whole process tree
  to prevent orphan sandbox workers holding the ACL publication lock.
- Preflight cleans only orphan sandbox workers whose parents no longer exist.
- Child git config appends workspace `safe.directory` while preserving existing
  `GIT_CONFIG_*` entries and leaving global config untouched.
- Hermetic lifecycle, process-tree kill, orphan cleanup and git config tests;
  updated English/Spanish documentation.

## 0.1.0 — 2026-10-06

First release of the Muse Code delegation lane.

- `muse-rescue` forwards bounded tasks to `muse exec --json` with a private
  prompt file, workspace sandbox, never-approve policy and a 9-minute timeout.
- Windows launcher discovery prefers the `.muse-version` binary, then another
  installed `muse-bin-*.exe`, then Muse on `PATH`; `MUSE_BIN` overrides all.
- Preflight verifies authentication and, on Windows, sandbox readiness.
- `--read-only` disables file writes and shell tools; quota and rate-limit
  failures are surfaced for fallback instead of retrying.
- JSONL progress filter, git metadata warnings, `/muse:rescue`, `/muse:setup`,
  delegation guide and English/Spanish READMEs.
