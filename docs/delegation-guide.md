# Multi-Agent Delegation Guide

Use Muse as the **second lane**, immediately after
[DeepSeek Harness](https://github.com/santiquiroz/deepseek-plugin-cc), and
before Codex, Copilot, Antigravity, Cursor and Ollama. Claude Code remains the
orchestrator.

## Lane split

| Lane | Use it for |
|---|---|
| DeepSeek Harness (`deepseek-plugin-cc`) | Preferred first agentic lane |
| **Muse (`muse-plugin-cc`)** | Bounded tasks: a spec, rename, boilerplate, one fix, focused investigation; read-only second opinions |
| Codex / Copilot / Antigravity / Cursor / Ollama | Next lane when Muse is unavailable, rate-limited or unauthenticated |
| Keep inline | Domain logic, business rules, architecture and anything whose WHY lives in this conversation |

Muse is slow: a trivial three-step task took about four minutes. Runs have a
9-minute cap, so delegate only self-contained, bounded work—not long
multi-step jobs. If quota, rate-limit or auth signals occur, stop and use the
next lane; never retry Muse automatically.

For an independent second opinion, use `/muse:rescue --read-only` and paste
the relevant code or diff into the task. Read-only mode disables both writes
and shell commands, so the delegate cannot fetch or inspect a diff itself.

## Safety and workspace setup

Muse's own OS sandbox confines writes to the workspace. The default sandbox
network is limited to Muse's proxy (`--sandbox-network proxy-only`); this
plugin does not enable the network or relax the sandbox. `--approval-mode
never` and `--approval-judge off` mean nothing is auto-approved or prompted.
The delegate can still commit inside the workspace: the forwarder compares
git metadata and prints `WARNING` lines for changes to `HEAD`, branch, stash,
config or hooks. Review those warnings and the working tree after every run.

On Windows, preflight requires `status=ready` from
`muse sandbox windows check`; initial setup requires an elevated terminal.
Known trap: Muse's sandbox shell hangs when the workspace is under the
signed-in user's `%USERPROFILE%\AppData` tree. Use a repository outside that
profile (for example, under a shared projects folder). The forwarder warns
but does not block such a run.

## Task shape and fallback

Write a self-contained task: paths, required behavior, constraints and
acceptance checks. Keep one deliverable per run. The task is sent to Muse via
a temporary prompt file, not an argv string. Do not work on the same files
while a delegated run is active.

On quota/rate-limit output, including `429`, quota, usage limit or insufficient
capacity, do not retry; move to the next lane or work inline. On `401`,
unauthorized or login output, run `muse login` in a normal terminal and then
`/muse:setup`.
