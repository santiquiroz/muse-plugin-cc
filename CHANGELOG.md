# Changelog

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
