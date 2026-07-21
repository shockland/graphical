# Graphical

Native macOS app for **graph engineering**: organize agent nodes (roles + models + loops) with explicit handoff contracts that pass context and decide who runs next.

## MVP scope

- YAML-in-repo org under `.graphical/`
- CLI-first pluggable agents (`runners.yaml`: command + kind + default model)
- Loop-per-node with artifact + shell + `router_next` done-checks
- Fixed edges + planner-router nodes, with optional `on: reject` edges for rework loops
- Opt-in edge approval gates
- Local SQLite traces + handoff inspector

## Requirements

- macOS 14+
- Swift 5.9+ / Swift 6 toolchain
- Full Xcode installed to run tests (`swift build`/`swift run` work with Command Line Tools alone, but `swift test` needs `DEVELOPER_DIR` pointed at a full Xcode install — see Tests below)

## Build & run

Native **AppKit** shell (not SwiftUI). SPM builds a bare executable; the app forces a regular activation policy so a window appears under `swift run`.

```bash
cd <path-to-your-clone-of-Graphical>
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift run Graphical
```

## Tests

Preferred entry point:

```bash
./scripts/test.sh
```

It sets `DEVELOPER_DIR` for you (if unset) and fails fast with a clear message if XCTest isn't available. Equivalent manual invocation:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
```

The engine vertical-slice test uses the seeded `echo_fixture` runner (no LLM required).

## Project layout on disk

```
<repo>/
  .graphical/
    project.yaml
    org.yaml
    runners.yaml
    layout.yaml          # canvas node positions (UI)
    artifacts/<runId>/...
  GOAL.md                # editable run goal (see Goal source below)
```

Runs and traces are stored in `~/Library/Application Support/Graphical/graphical.sqlite`.

## Multi-user / git

`.graphical/` is meant to be YAML-in-repo: roles, edges, instructions, and done-checks are the shared org graph. Do **not** gitignore the whole directory unless the team treats Graphical as personal tooling only.

For multi-user repos, ignore runtime and UI-local files:

```gitignore
# Graphical — local / noisy
.graphical/artifacts/
.graphical/layout.yaml
```

The app can ensure the artifacts ignore via **Artifacts .gitignore** in the Run console (writes `.graphical/artifacts/.gitignore`).

Per-node `runner` / `model` and `runners.yaml` often differ by machine (Cursor vs Claude, model picks). Either agree on one coding tool for the shared org, or expect diffs when each person rebinds tools after clone. `GOAL.md` / `project.yaml`'s live `goal` are also noisy during active work — commit them when the goal is a shared contract, not mid-run scratch.

## App flow

1. **Create / Open** a project folder — Create (or Open of a folder without `.graphical`) opens a setup sheet: goal → coding tool, then lands on the **Workflow** canvas (Planner → Implementer → Reviewer). Setup does not auto-start a run.
2. Edit **Workflow** nodes and edges (Save writes YAML), or press **Run workflow** from the Project Guide when ready
3. Choose a **coding tool** via Project Guide or **Agents → Set up coding tool…** (preset wizard with install detection). The Agents tab still exposes raw CLI templates for power users. Cursor presets include `--output-format stream-json --stream-partial-output` so the Run console can show incremental agent text; existing project `runners.yaml` entries need those flags added under `-p` to get the same live feedback (durable traces stay redacted unless `traceCLIOutput` is enabled).
4. **Run** with a goal; approve the gated Planner → Implementer handoff (first-run tips explain approval vs reject edges)
5. Inspect **History** and export JSON

## Goal source

`GOAL.md` at the project root is the editable source of truth for the run goal:

- **Open/Create**: if `GOAL.md` (the `goalFile` named in `project.yaml`) exists and is non-empty, its trimmed contents populate the goal shown in the Run console. Otherwise the YAML `goal` field in `project.yaml` is used.
- **Save**: the Run console's goal text is written to both `GOAL.md` and `project.yaml`'s `goal` field, so they stay in sync.
- If two edits conflict (e.g. someone hand-edits `GOAL.md` while the app has unsaved changes), the next Save simply overwrites `GOAL.md` with the app's in-memory draft — there is no merge UI.

## Done-checks, Apply, and reject edges

Each node's `done` group (`all_of` / `any_of`) is made of:

- `artifact: <path>` — file must exist and be non-empty, resolved relative to that node's artifacts directory (path traversal outside it is rejected).
- `shell: <command>` — run via `/bin/bash -c`, non-login shell, with a minimal environment (`PATH`/`HOME`/`TMPDIR`/`USER`/`LOGNAME`) rather than the full host environment, so checks can't read host secrets.
- `router_next: true` — the node must write `next.json` (`{"node_id": "...", "reason": "..."}`) choosing where to go next.

An **empty** `all_of`/`any_of` group always fails (it does not pass vacuously).

In the inspector, editing a node's artifact list via **Apply Node** preserves any existing `shell` checks on that node — only the artifact entries are replaced.

A node whose done-checks already passed can still write `reject.json` (`{"reject": true, "reason": "..."}`) into its own artifacts to say "send this back" instead of advancing along its normal success edge. If it has a matching outgoing edge with `on: reject`, the run routes there instead. Writing `reject.json` on a node with **no** matching reject edge fails the run with a clear error rather than being silently ignored. This is distinct from the Run console's Approve/Reject buttons, which accept or reject a *pending approval gate* on a router edge — approval rejection fails the run outright and does not use `reject.json`.

## Limitations / trust

Graphical runs arbitrary local CLI agents and shell commands on your behalf. Keep these in mind:

- **Traces may still be sensitive.** By default (`traceCLIOutput: false`), the SQLite trace store does not persist raw agent stdout/stderr — only sizes and exit status. Opting a project into `traceCLIOutput: true` adds a short preview of stdout, which can include secrets echoed by the agent or its tools. Handoff summaries, artifact paths, and done-check details are always stored and exported, and may themselves leak sensitive text an agent chose to write.
- **The trace database lives at** `~/Library/Application Support/Graphical/graphical.sqlite` and is not encrypted; exported trace JSON carries the same caveats.
- **Shell done-checks run with a minimal environment**, not your full shell environment — this limits (but does not eliminate) what a check command can read.
- **Runner templates execute real subprocesses** (e.g. `claude`, `agent`, or arbitrary commands from `runners.yaml`). Review `runners.yaml` and node instructions before running a project you didn't author.

## Domain language

| Concept | Meaning |
|---------|---------|
| Org graph | Stable roles, agents, model overrides, handoff edges |
| Work graph / Run | Dynamic instance for one goal |
| Node loop | Invoke CLI until done-checks pass or budget hits |
| Handoff contract | summary + artifacts + checks (+ router next) — not full transcripts |
| Reject edge | `on: reject` edge a node can trigger via `reject.json` to send work back instead of advancing |
| Goal source | `GOAL.md`, kept in sync with `project.yaml`'s `goal` field on Save |
