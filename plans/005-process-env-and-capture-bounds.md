# Plan 005: Process env isolation + stdout/stderr capture bounds

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalCLI/ProcessRunner.swift Sources/GraphicalEngine/DoneCheckEvaluator.swift Sources/GraphicalCLI/ModelCatalog.swift`

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: security
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

`ProcessRunner` always starts from `ProcessInfo.processInfo.environment` and merges the caller map. Done-checks pass `environment: [:]` expecting isolation but still inherit host secrets (API keys). Separately, stdout/stderr are appended unboundedly into memory before any truncation for traces.

## Current state

`Sources/GraphicalCLI/ProcessRunner.swift:89-93`:

```swift
var env = ProcessInfo.processInfo.environment
for (key, value) in environment {
    env[key] = value
}
process.environment = env
```

`DoneCheckEvaluator.swift:65-70` passes `environment: [:]`.

Capture: `DataBox` appends with no max (`ProcessRunner.swift:101-160`).

Protocol today (`ProcessRunner.swift:32+`):

```swift
public protocol ProcessExecuting: Sendable {
    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int
    ) async throws -> ProcessResult
}
```

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `./scripts/test.sh` | exit 0 |
| Build | `swift build` with DEVELOPER_DIR | exit 0 |

## Scope

**In scope**:
- `Sources/GraphicalCLI/ProcessRunner.swift`
- Call sites: `DoneCheckEvaluator`, CLIRunner / ModelCatalog if they call `run`
- Tests for ProcessRunner (new file under GraphicalEngineTests or a GraphicalCLI test target — **prefer** adding tests to existing EngineTests with `@testable import GraphicalCLI`, or DomainTests if you add a CLI test target in Package.swift — adding a test target is OK if minimal)

**Out of scope**:
- Full AsyncBytes rewrite
- Trace redaction policy (011)
- Template escaping (010)

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Clarify environment semantics

Change API to one of these (pick A):

**A (recommended):** add parameter `inheritEnvironment: Bool = true`.  
- `true` (runners): current merge behavior.  
- `false` (done-checks): start from **minimal allowlist** only: `PATH`, `HOME`, `TMPDIR`, `USER`, `LOGNAME` (copy from process env if present), then merge the provided `environment` map.

**B:** `environment: [String: String]?` where `nil` = inherit, non-nil = replace entirely — but then done-checks need PATH; still use allowlist seed.

Update `DoneCheckEvaluator` to `inheritEnvironment: false` (or equivalent).

**Verify**: `swift build` exits 0; all call sites compile.

### Step 2: Cap capture

- Max e.g. 1 MiB combined or 512 KiB per stream (document constant).
- Stop appending after cap; set `ProcessResult.truncated = true` (add property, default false).
- Do not change exit-code semantics.

**Verify**: unit test that a process writing large stdout returns truncated flag and bounded string size.

### Step 3: Done-check uses non-login shell if easy

While touching DoneCheckEvaluator, change `["-lc", command]` → `["-c", command]` (drop login `-l`). If a seed check depends on login PATH, use absolute paths in seed — seed currently uses simple commands.

**Verify**: `./scripts/test.sh` including vertical slice still passes.

## Test plan

- inheritEnvironment false does not contain a planted secret key from a test harness… (injecting process env in unit tests is hard). Prefer: assert that when inherit is false and environment is `["FOO":"bar"]`, the child sees FOO (echo test) and document allowlist. Optional: skip secret-inheritance assertion if not practical.
- Truncation test with `yes` or python writing bytes — careful with timeout; prefer a small Swift/bash that writes N megabytes.

## Done criteria

- [ ] Done-checks do not full-inherit host env
- [ ] Capture is bounded + truncation flag
- [ ] `-c` not `-lc` for done-checks (unless STOP)
- [ ] `./scripts/test.sh` exits 0
- [ ] `plans/README.md` row 005 → DONE

## STOP conditions

- ModelCatalog / Cursor discovery breaks without full env — keep `inheritEnvironment: true` for those call sites.
- Truncation breaks vertical slice assertions that inspect stdout — raise cap only as needed, do not remove the cap.

## Maintenance notes

- Reviewers: every new `processRunner.run` must choose inherit explicitly.
- Plan 010 builds on safer process defaults.
