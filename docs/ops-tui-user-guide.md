# phantomos ops — operator guide

A keyboard-driven menu of every script in this repo, organised by what
you're trying to do — not by which file does it. Hides the script
names; shows them only on demand. Confirms before anything
destructive. Streams output without crashing if a script does.

> Adding new functions? See [ops-tui-dev-guide.md](./ops-tui-dev-guide.md).

## What you see when you launch it

```
┌─ phantomos ops ─────────────────────────────────────────────────────── 03:14 ──┐
│ host hw-thor01 ✓   robot hwthor01   kubectl k0s ✓   argocd Synced   ● online   │
├──────────────────┬─────────────────────────────────────┬───────────────────────┤
│   Bootstrap      │ ●  Show what positronic-control is  │ Show what positronic- │
│ ▸ Workloads      │    doing right now                  │ control is doing      │
│   Recording      │ ●  Tail positronic-control logs     │ right now             │
│   Registry       │ ●  Drop into a shell (positronic)   │ ─────────────────     │
│   Builds         │ ●  Drop into a shell (locomotion)   │                       │
│   Diagnostics    │ ●  Diagnose unhealthy positronic    │ Snapshot of pod       │
│                  │ ⚠  Tear down + rebuild stateful     │ state: QoS, restarts, │
│                  │    resources                        │ runtimeClass,         │
│                  │                                     │ PHANTOM_CMD (CM +     │
│                  │                                     │ as-seen by pod),      │
│                  │                                     │ PID 1 cmd.            │
│                  │                                     │                       │
│                  │                                     │  Read-only            │
│                  │                                     │  ~1 second            │
│                  │                                     │  needs kubectl        │
│                  │                                     │  runs anywhere        │
│                  │                                     │                       │
│                  │                                     │ ▸ Show command (c)    │
├──────────────────┴─────────────────────────────────────┴───────────────────────┤
│ ↵ run   e edit args   d dry-run   c show command   f favorite                  │
│ / search   ? help   q quit                                                     │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Three panes:** groups (left), actions in the selected group (middle),
detail for the highlighted action (right).

**Header strip** is your current environment at a glance. If something
is missing — no kubectl, ArgoCD unreachable, robot not labelled — it
shows there, and any action that depends on it greys out with the
reason. You can't accidentally pick something that can't possibly
work.

## What's in each group

| Group | What lives there |
|---|---|
| **Bootstrap & Host** | First-time bringup, host config edits, registry mirror wiring, NVIDIA runtime, real-time CPU partitions, EtherCAT NIC pinning |
| **Workloads** | positronic-control + phantom-locomotion lifecycle: status, logs, exec, diagnose, full reset |
| **Recording & Streams** | dma-recorder commands: start, stop, ping, raw opcode |
| **Registry** | Pre-pull images, prune tags, resize PVC, validate, recover stuck volumes |
| **Builds** | phantom-models / phantom-policies image build + push |
| **Diagnostics** | System perfmon, registry health, positronic diagnose |

## Reading the safety markers

```
   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
   │   ●  green  │    │  ●  yellow  │    │    ⚠  red   │
   │             │    │             │    │             │
   │  read-only  │    │  changes    │    │  destructive│
   │  fires on ↵ │    │  state but  │    │  or hard to │
   │             │    │  reversible │    │  reverse —  │
   │             │    │  fires on ↵ │    │  must type  │
   │             │    │             │    │  magic word │
   └─────────────┘    └─────────────┘    └─────────────┘
```

Every action carries one. The detail pane has the same color as a
band on its left edge so you don't lose the signal while reading.

## When you pick a destructive action

```
┌─ Confirm ─────────────────────────────────────────────────────┐
│                                                               │
│  ⚠  Tear down + rebuild stateful resources                    │
│                                                               │
│  This will delete:                                            │
│   • Argo Application  phantomos-hwthor01-core                 │
│   • Workloads in      phantom, positronic, nimbus, argus      │
│   • PVCs (on-disk data preserved at /var/lib/...)             │
│                                                               │
│  ArgoCD recreates everything from git. Recovery time          │
│  typically 3–8 min depending on image cache state.            │
│                                                               │
│  Type "reset" to proceed:  ▌                                  │
│                                                               │
│            [ Cancel  esc ]                  [ Proceed  ↵ ]    │
└───────────────────────────────────────────────────────────────┘
```

The magic word is action-specific (`reset`, `wipe`, `prune`,
`bootstrap`, `proceed`) so muscle memory from one modal can't fire
another. Once you've confirmed an action this session, re-running it
after a transient failure won't re-prompt.

## When an action has options

Five high-frequency actions open a parameter form instead of running
straight away:

```
┌─ Tail positronic-control logs ────────────────────────────────────────────────┐
│                                                                               │
│   Container        (●) main           ( ) load-models init                    │
│   Follow           [✓] -f                                                     │
│   Previous run     [ ] --previous                                             │
│   Lines            [ 500          ]                                           │
│                                                                               │
│   Command preview                                                             │
│     bash scripts/positronic.sh logs -f --tail 500                             │
│                                                                               │
│           [ Cancel  esc ]                                  [ Run  ↵ ]         │
└───────────────────────────────────────────────────────────────────────────────┘
```

The command preview at the bottom updates live as you tweak fields —
last sanity check before you fire it. Form values stick: the next
time you open that action, your previous choices are pre-filled.

The five forms are:
- Tail positronic-control logs
- Drop into a shell (target: positronic | locomotion)
- Send a raw opcode
- Pre-pull upstream images
- List or remove tags

Every other action just runs on `↵`.

## When something is running

```
┌─ phantomos ops ─────────────────────────────────────────────────────── 03:14 ──┐
│ host hw-thor01 ✓   robot hwthor01   kubectl k0s ✓   ●  Running: prime cache    │
├──────────────────┬─────────────────────────────────────────────────────────────┤
│   Bootstrap      │  ▶  Pre-pull upstream images into the local registry        │
│ ▸ Workloads      │  ────────────────────────────────────────────────────────   │
│   Recording      │  bash scripts/prime-registry-cache.sh --filter foundation*  │
│   Registry       │                                                             │
│   Builds         │  [00:01]  fetching foundationbot/phantom-cuda:0.2.46…       │
│   Diagnostics    │  [00:14]  ▓▓▓▓▓▓▓▓░░░░░░░  43%   1.2 GB / 2.8 GB             │
│                  │  [00:32]  pushed → localhost:5443/phantom-cuda:0.2.46       │
│                  │  [00:33]  fetching foundationbot/phantom-models:2026-05-05  │
│                  │  ▌                                                          │
├──────────────────┴─────────────────────────────────────────────────────────────┤
│ ctrl-c cancel   p pause scroll   s save log   esc back to menu (keep running)  │
└────────────────────────────────────────────────────────────────────────────────┘
```

Output streams live. `esc` takes you back to the menu — the job keeps
going in the background, and a `▶` badge on the header reminds you
it's running. You can fire other actions while it runs; each gets its
own log pane.

`ctrl-c` cancels gracefully: SIGINT first, SIGTERM after 3 s, SIGKILL
after 8 s. You're never stranded waiting on a stuck process.

## Navigating

```
   ↑ ↓        move within the list
   ← →        switch panes (groups → actions → detail)
   tab        next pane
   /          fuzzy search across all actions
   g 1..6     jump to group N

   ↵          run the selected action
   e          open the parameter form
   d          run with --dry-run if the script supports it
   c          toggle command preview in the detail pane
   f          favorite (pinned to top of the group)

   ctrl-c     cancel the running job
   p          pause autoscroll
   s          save the running output to a file
   esc        return to menu, keep job running

   ?          help overlay
   q          quit
```

## Why it doesn't crash

Every script runs in its own subprocess sandbox. If a script fails —
non-zero exit, killed signal, OOM — you see a banner in the output
pane. The TUI keeps going.

If something goes wrong inside the TUI itself, you get a recovery
modal ("Something unexpected happened; press R to reload, Q to quit,
L to view log") instead of a Python traceback. The full traceback
lands in `~/.local/state/phantomos-ops/crash.log` for forensics.

Your favorites, last-used form values, and window layout are saved to
`~/.config/phantomos-ops/state.json` and restored on next launch.

If you start a second instance on the same host (e.g. re-attaching to
tmux) it opens read-only and tells you the other one is in charge.

## Modes

```
phantomos-ops                              # interactive
phantomos-ops --read-only                  # demo / over-the-shoulder
phantomos-ops run streams.record_start     # one-shot, script-friendly
phantomos-ops list                         # all action ids (for tab-complete)
```

`--read-only` hides everything yellow + red, so you can show the menu
to someone without risk of fat-fingering. `run <id>` is for systemd
timers / cron / one-line invocations that don't want the menu.
