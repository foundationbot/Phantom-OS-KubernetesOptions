# phantomos ops — developer guide

How to add new functions to the TUI. The principle: **the manifest is
the source of truth, the TUI is a renderer**. Most additions are one
YAML stanza. No Python required unless you want a parameter form.

> Operator-facing docs: see [ops-tui-user-guide.md](./ops-tui-user-guide.md)

## The 60-second add

You wrote a new script: `scripts/registry-gc.sh`. To make it
discoverable in the TUI, append this to
`tools/phantomos-ops/manifest.yaml`:

```yaml
- id: registry.gc
  group: registry
  title: "Run registry garbage collection"
  blurb: "Reclaims disk after tag deletions."
  safety: yellow
  requires: [kubectl]
  duration: "1-5 min"
  command: ["bash", "scripts/registry-gc.sh"]
```

That's it. Save, relaunch `phantomos-ops`, the action appears under
**Registry**, coloured yellow, fires on `↵`. No Python touched. The
operator sees:

```
   Registry
   ──────────
   ●  Pre-pull upstream images into the local registry
   ●  List or remove tags & reclaim disk
   ●  Resize the registry's storage
   ●  Verify the local registry is wired up correctly
   ●  Recover a stuck (Lost) volume claim
   ●  Run registry garbage collection         ← new
```

## Anatomy of a manifest entry

```yaml
- id: registry.gc                    # stable identifier (group.short_name)
  group: registry                    # one of the group ids
  title: "Run registry garbage collection"     # what the operator reads
  blurb: |                                     # detail-pane description
    Reclaims disk on the host registry by removing
    blobs no longer referenced by any tag.
  safety: yellow                     # green | yellow | red
  runs_on: [robot, dev]              # robot | dev | both — gates by env
  requires: [kubectl]                # capabilities — gates by env probe
  duration: "1-5 min"                # informational, shown in detail
  reversible: true                   # red + reversible:false → confirm modal
  command: ["bash", "scripts/registry-gc.sh"]
  dry_run: ["bash", "scripts/registry-gc.sh", "--dry-run"]   # optional
  form: null                         # null = launcher-only; or "module_name"
  confirm_word: null                 # required when safety: red
```

| Field | Required | Purpose |
|---|---|---|
| `id` | ✓ | Stable across renames; used for favorites, `phantomos-ops run <id>`, persisted form values |
| `group` | ✓ | Must match a `groups[].id` |
| `title` | ✓ | Operator intent. Verb phrase, sentence case, no script names |
| `blurb` | ✓ | 1–4 lines of detail-pane copy |
| `safety` | ✓ | Drives colour, default-confirm behaviour |
| `command` | ✓ | argv list — what gets exec'd. No shell interpolation |
| `runs_on` | – | Defaults to `[robot, dev]` |
| `requires` | – | Capabilities the env probe knows about: `kubectl`, `argocd`, `recorder_pod`, `root` |
| `duration` | – | Operator hint (e.g. "~1s", "3-8 min") |
| `reversible` | – | Defaults to `true` for green/yellow, `false` for red |
| `dry_run` | – | If present, `d` runs this instead of `command` |
| `form` | – | Module name under `forms/` for parameter-aware actions |
| `confirm_word` | – | Magic word for the confirm modal. Required when `safety: red` |

## Adding a parameter form

Five high-frequency actions get forms. Adding a sixth is a manifest
field plus one Python module.

### Manifest entry

```yaml
- id: registry.prune
  group: registry
  title: "List or remove tags & reclaim disk"
  blurb: "Removes matching tags from the local registry."
  safety: red
  confirm_word: "prune"
  requires: [kubectl]
  form: registry_prune                # ← references forms/registry_prune.py
```

Note: when you set `form:`, you don't need `command:` — the form
builds it.

### Form module

```python
# tools/phantomos-ops/src/phantomos_ops/forms/registry_prune.py
from phantomos_ops.forms import ActionForm
from textual.widgets import Input, Switch

class RegistryPruneForm(ActionForm):
    """List or remove tags from the local registry."""

    def compose_fields(self):
        yield self.field("Pattern",
            Input(placeholder="e.g. mirror-test-*",
                  id="pattern"))
        yield self.field("Dry run",
            Switch(value=True, id="dry_run"))
        yield self.field("Garbage-collect after",
            Switch(value=False, id="gc_after"))

    def to_command(self) -> list[str]:
        cmd = ["bash", "scripts/prune-registry-tags.sh",
               self.value("pattern")]
        if self.value("dry_run"):  cmd.append("--dry-run")
        if self.value("gc_after"): cmd.append("--gc-after")
        return cmd
```

The base class `ActionForm` handles:

- Field layout + the live command-preview pane
- Persisting field values per action id (next time you open the
  form, your last entries are pre-filled)
- Cancel / Run buttons
- Plumbing into the runner and the confirm modal (if `safety: red`)

You only write `compose_fields()` and `to_command()`.

### Form lifecycle

```
   ┌─ operator hits 'e' on a form-aware action ──────────────────┐
   │                                                             │
   │   1.  ActionForm instantiated, field defaults restored      │
   │       from ~/.config/phantomos-ops/state.json               │
   │                                                             │
   │   2.  Operator edits fields                                 │
   │       └─▶ to_command() called on every change               │
   │           └─▶ command preview pane updates live             │
   │                                                             │
   │   3.  Run pressed                                           │
   │       ├─▶ field values persisted                            │
   │       ├─▶ if safety: red → confirm modal                    │
   │       └─▶ runner.run(to_command()) → run-screen             │
   └─────────────────────────────────────────────────────────────┘
```

## Choosing the safety class

```
              ┌──────────────────────────────────┐
              │  Does it write anything? (cluster│
              │  state, files on disk, registry, │
              │  systemd units, kubelet config)  │
              └────────────┬─────────────────────┘
                           │
                ┌──────────┴──────────┐
              no│                     │yes
                ▼                     ▼
            ●  green       ┌─────────────────────────┐
                           │  Reversible by re-running│
                           │  the same action, or by  │
                           │  ArgoCD reconciliation?  │
                           └────────────┬─────────────┘
                                        │
                              ┌─────────┴─────────┐
                            yes│                  │no
                               ▼                  ▼
                           ●  yellow          ⚠  red
                                              + confirm_word
```

Green examples: `positronic.sh status`, `validate-local-registry.sh`,
`thor-perfmon.py`, `dma-cmd.sh ping`.

Yellow examples: `prime-registry-cache.sh`, `dma-cmd.sh record start`,
`configure-host.sh`, `bootstrap-robot.sh` on a fresh host.

Red examples: `reset-deployment.sh`, `resize-registry-pvc.sh`,
`prune-registry-tags.sh` (without dry-run), `bootstrap-robot.sh` on a
populated host.

When unsure, **start yellow**. You can promote later without breaking
operator muscle memory; demoting from red to yellow does break it.

## Adding a new group

```yaml
groups:
  - id: dataops                        # stable id for the group
    title: "Data Ops"                  # left-pane label
    order: 7                           # vertical position
```

Any action with `group: dataops` files into it. Order numbers don't
have to be contiguous; gaps make insertion easier later.

Use a new group when:

- The set of actions has its own mental model that doesn't fit the
  existing six
- An existing group is approaching ~7 actions and a clean split
  exists

Avoid creating a group for one or two actions — they fit better as
yellow entries in **Workloads** or **Diagnostics**.

## Promoting an action over time

| Stage | Action | What you change |
|---|---|---|
| Day 1: just landed | Add launcher-only entry, mark `yellow` if unsure | Manifest only |
| Used regularly with >1 common arg set | Promote to form-aware | Manifest `form:` field + `forms/<id>.py` |
| Has a destructive failure mode | Bump to `red`, add `confirm_word` | Manifest `safety` + `confirm_word` |
| Daily-use entry | Operators pin with `f`; consider it for the help-overlay's "Common actions" tab | No dev work |
| Superseded / removed | Mark `deprecated: true` (banner in detail pane) for one release, then delete | Manifest |

Action ids are stable contracts — favorites, persisted form values,
and `phantomos-ops run <id>` all reference them. Renaming an id is
a breaking change for operators.

## Testing your entry

```bash
# 1. Schema validation — bad entries surface here, not at runtime
phantomos-ops list

# 2. Dry-run the command resolution
phantomos-ops run my.new_action -d

# 3. Eyeball it in the menu
phantomos-ops

# 4. If it has a form, test field persistence:
#    open form → set fields → cancel → reopen → verify pre-fill
```

The schema validator is strict by design — a malformed entry shows
up as a startup banner and gets dropped from the menu. The TUI never
runs with a broken manifest silently.

For form modules, the test suite (`tools/phantomos-ops/tests/`) has:

- `test_manifest.py` — every entry validates against the schema
- `test_forms.py` — every form module's `to_command()` runs without
  exceptions on default values

Add a test there if your form has non-trivial validation logic.

## What you don't touch

```
   tools/phantomos-ops/src/phantomos_ops/
   ├── app.py              ← framework — manifest-driven, generic
   ├── manifest.py         ← loader + schema validator
   ├── env.py              ← env probe — extend only when adding new
   │                          requires: capability
   ├── runner.py           ← subprocess + stream + cancellation
   ├── state.py            ← persistence
   ├── safety.py           ← safety class → glyph/colour/confirm logic
   ├── theme.tcss          ← colours, spacing — for designers
   ├── screens/
   │   ├── main.py         ← three-pane menu
   │   ├── run.py          ← running-job log view
   │   ├── confirm.py      ← red-action confirm modal
   │   └── help.py         ← help overlay
   ├── forms/              ← per-action parameter forms ← YOU ADD HERE
   │   ├── __init__.py     ← ActionForm base class
   │   ├── positronic_logs.py
   │   ├── positronic_exec.py
   │   ├── dma_raw.py
   │   ├── prime_cache.py
   │   └── prune_tags.py
   └── manifest.yaml       ← single source of truth ← YOU EDIT HERE
```

The framework files are intentionally generic. If you find yourself
wanting to special-case an action there — stop and think whether it
belongs in the manifest or a form module instead. The whole point of
the design is that adding actions doesn't require touching the
renderer.

Exceptions where touching framework code is correct:

- Adding a new capability the env probe should detect (e.g.
  `requires: [redis_running]`) — extend `env.py` and `safety.py`
- Adding a new safety class — extend `safety.py` (rare)
- Theme tweaks — `theme.tcss`
- Bug fixes in screens/runner

## Conventions

### Action ids

- Format: `<group>.<short_name>`
- Lowercase, snake_case
- Examples: `registry.prune`, `streams.record_start`,
  `bootstrap.cpusets`
- Stable across renames — they're persisted in operator state

### Titles

- Operator intent, not script names. "Tail logs", not
  "positronic.sh logs".
- Verb phrase. "Tear down + rebuild stateful resources", not
  "Stateful resource teardown".
- Sentence case. "Show what positronic-control is doing right now",
  not "Show What Positronic Control Is Doing Right Now".
- Don't mention `kubectl`, `bash`, paths, or flags — the command
  preview shows those.

### Blurbs

- 1–4 lines. Operator-facing. Plain English.
- Lead with what changes, not how it works.
- For destructive actions, list what gets deleted explicitly.
- Don't repeat the title.

### Commands

- Always use the argv list form: `["bash", "scripts/foo.sh", "arg"]`.
  Never a single shell string — that opens injection holes when forms
  feed in user values.
- Paths are relative to the repo root.
- `bash scripts/foo.sh` not `./scripts/foo.sh` — the latter requires
  the script be marked executable, which not all are.

## Common patterns

### Action that needs the robot identity

```yaml
- id: workloads.exec_locomotion
  ...
  command: ["bash", "scripts/positronic.sh", "exec", "locomotion"]
```

The TUI doesn't pass robot identity itself — scripts read it from
`/etc/phantomos/robot` (via `lib/robot-id.sh`). One source of truth.

### Action that should be hidden in read-only mode

Already automatic: `--read-only` hides everything yellow + red.
Nothing to configure.

### Action that needs a recorder pod to exist

```yaml
- id: streams.record_start
  ...
  requires: [kubectl, recorder_pod]
```

The `recorder_pod` capability is checked by `env.py` — if no
`dma-recorder` pod is running, the action greys out with the reason.

### Action that should propagate exit codes specially

The runner always propagates the script's exit code. Don't try to
mask failures — if the script exits non-zero, the run-screen shows
the banner and the operator decides what to do. This is intentional;
silent success-on-failure is worse than visible failure.

## Making the development experience intuitive

Three principles the framework enforces so additions stay easy:

1. **Most additions are YAML, not Python.** The bar to add a new
   action is "edit one file and save".
2. **Schema validation is loud at startup, silent at runtime.**
   Manifest errors show up in a startup banner, never as a crash
   mid-action.
3. **Forms are a small, well-scoped extension surface.** A form
   module is two methods: `compose_fields` and `to_command`. No
   widget hierarchy, no event wiring.

If the friction to add a new action grows beyond "edit
manifest.yaml" for the simple case or "+ one Python file" for the
form case, that's a regression — open an issue.
