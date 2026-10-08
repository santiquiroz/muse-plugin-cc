# Delegation Guide

Use Muse for bounded tasks: a spec, rename, boilerplate, one fix or a
focused investigation. Claude Code remains the orchestrator.

Muse is slow: trivial tasks take 25 s to several minutes, so run it in the
background and keep working. Detached runs last up to 45 minutes by default
(`MUSE_RESCUE_MAX_SECONDS=2700`). The subagent calls `start`, then repeats
foreground `wait <id>` calls in 480-second slices (maximum 540); exit 75 means
still running. A wait past the deadline kills the process tree with exit 124.
An interrupted subagent leaves the job running: retain its id to `wait` or
`cancel` later (exit 130). Edits remain in the working tree. The `run` command
keeps a short default limit of 540 seconds (`MUSE_RESCUE_TIMEOUT` overrides the
seconds). 3–4 concurrent jobs on different files work fine; do not work on the
same files while a delegated run is active.

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

## Task shape

Write a self-contained task: paths, required behavior, constraints and
acceptance checks. Keep one deliverable per run. The task is sent to Muse via
a temporary prompt file, not an argv string. Do not work on the same files
while a delegated run is active.

Review `git status` and `git diff` after every run, along with every
`[muse-rescue] WARNING:` line. The constraints in the prompt are not a
sandbox: Muse may commit inside the workspace.

On quota/rate-limit output, including `429`, quota, usage limit or insufficient
capacity, stop and report it; never retry Muse automatically. On `401`,
unauthorized or login output, run `muse login` in a normal terminal and then
`/muse:setup`.

## Using it with other delegates

If you use several delegation plugins, define their order in your own
`CLAUDE.md`; this plugin does not assume any other delegate exists.
