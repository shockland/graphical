# Graphical

Native macOS app for **graph engineering**: organize agent nodes (roles + models + loops) with explicit handoff contracts that pass context and decide who runs next.

## MVP scope

- YAML-in-repo org under `.graphical/`
- CLI-first pluggable agents (`runners.yaml`: command + kind + default model)
- Loop-per-node with artifact + shell done-checks
- Fixed edges + planner-router nodes
- Opt-in edge approval gates
- Local SQLite traces + handoff inspector

## Requirements

- macOS 14+
- Swift 5.9+ / Swift 6 toolchain
- Full Xcode optional (SPM builds the app executable)

## Build & run

Native **AppKit** shell (not SwiftUI). SPM builds a bare executable; the app forces a regular activation policy so a window appears under `swift run`.

```bash
cd /Users/chris/Projects/Graphical
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift run Graphical
```

## Tests

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

The engine vertical-slice test uses the seeded `echo_fixture` runner (no LLM required). XCTest requires the full Xcode toolchain (`DEVELOPER_DIR` as above), not Command Line Tools alone.

## Project layout on disk

```
<repo>/
  .graphical/
    project.yaml
    org.yaml
    runners.yaml
    layout.yaml          # canvas node positions (UI)
    artifacts/<runId>/...
```

Runs and traces are stored in `~/Library/Application Support/Graphical/graphical.sqlite`.

## App flow

1. **Create / Open** a project folder
2. Edit **Org** nodes and edges (Save writes YAML)
3. Configure **Agents** (CLI templates + kind + default model)
4. **Run** with a goal; approve gated handoffs
5. Inspect **Trace** and export JSON

## Domain language

| Concept | Meaning |
|---------|---------|
| Org graph | Stable roles, agents, model overrides, handoff edges |
| Work graph / Run | Dynamic instance for one goal |
| Node loop | Invoke CLI until done-checks pass or budget hits |
| Handoff contract | summary + artifacts + checks (+ router next) — not full transcripts |
