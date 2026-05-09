# phantomos-ops

Textual TUI launcher for the operator scripts in this repo.

User and developer guides live alongside the rest of the docs:

- [Operator guide](../../docs/ops-tui-user-guide.md) — what you see and how to use it.
- [Developer guide](../../docs/ops-tui-dev-guide.md) — how to add new actions.

## Install (dev)

```bash
cd tools/phantomos-ops
pipx install --editable .
phantomos-ops
```

## Layout

```
src/phantomos_ops/
├── __main__.py        entry point
├── app.py             Textual App + screens wiring
├── env.py             environment probe (kubectl, robot id, online)
├── manifest.py        manifest loader + schema validator
├── manifest.yaml      single source of truth — the action registry
├── runner.py          subprocess worker with stream + cancellation
├── safety.py          green/yellow/red classification + glyphs
├── state.py           favorites + form values persistence
├── theme.tcss         visual theme
├── screens/           main, run, confirm, help
└── forms/             per-action parameter forms
```

The framework files are generic — most additions are one YAML stanza
in `manifest.yaml`. See the developer guide for the full extension
contract.
