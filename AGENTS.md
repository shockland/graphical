# Agent notes for Graphical

Guidance for AI agents (and humans) working in this repo.

## Requirements

- macOS 14+
- Full Xcode installed (Command Line Tools alone are not enough — `swift test`
  fails with `no such module 'XCTest'` without it).
- Always `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  before `swift build` / `swift test`.

## Verifying changes

Prefer the wrapper script over raw `swift test`:

```bash
./scripts/test.sh
```

It sets `DEVELOPER_DIR` for you (if unset) and fails fast with a clear message
if XCTest isn't available. Equivalent manual invocation:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
```

## Target map

```
GraphicalDomain  →  GraphicalCLI  →  GraphicalEngine  →  GraphicalApp
```

- `GraphicalDomain` — pure models, YAML store, validation. No AppKit, no I/O beyond files.
- `GraphicalCLI` — process execution (`ProcessRunner`), template rendering.
- `GraphicalEngine` — run loop, done-check evaluation, trace store. Depends on Domain + CLI.
- `GraphicalApp` — AppKit shell (executable). Depends on all of the above.

Dependencies only flow left-to-right above; don't introduce back-edges.

## Testing conventions

- Prefer tests in `GraphicalDomainTests` / `GraphicalEngineTests`. Avoid AppKit
  in unit tests — `GraphicalApp` has no test target.
- Engine tests use temp directories and `TraceStore(inMemory: true)`; see
  `Tests/GraphicalEngineTests/RunEngineTests.swift` for the pattern.

## Do not touch

- `.build/` — SwiftPM build products.
- `.graphical/artifacts/` — run artifacts, not source.

## Plans

Implementation plans (and their status) live in `plans/`. Read the relevant
plan fully before making changes in its scope; follow its STOP conditions.

Read README's Domain language + Limitations sections before changing
RunEngine routing (reject edges, done-checks, goal source).
