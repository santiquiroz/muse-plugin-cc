---
description: Check Muse CLI installation, authentication, Node.js and Windows sandbox readiness
argument-hint: ""
allowed-tools: Bash
---

Run the shared preflight and report its output without revealing credentials:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/muse-forward.sh" preflight
```

Handle failures:

- **127**: install Muse Code or ensure `muse` is on `PATH`; install Node.js and
  ensure `node` is on `PATH` for the JSONL filter. On Windows, the per-user
  install's `muse.cmd` is a launcher; this plugin prefers the versioned binary
  beside it. Run `/muse:setup` again.
- **70**: run `muse login` once in a normal terminal, then rerun `/muse:setup`.
- **78**: run `muse sandbox windows setup` once from an elevated terminal,
  then rerun `/muse:setup`.

Never print the contents of Muse's auth file or an API key.
