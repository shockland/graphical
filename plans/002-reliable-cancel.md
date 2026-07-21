# Plan 002: Reliable cancel (engine + process kill)

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report — do not improvise. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalEngine/RunEngine.swift Sources/GraphicalCLI/ProcessRunner.swift Tests/GraphicalEngineTests/`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

`cancel()` marks the run `.cancelled` in SQLite while the actor may still be inside `cli.invoke`. After the CLI returns, the loop continues and can overwrite status to `.failed` or `.succeeded`. Cancel is not trustworthy for users or for AppModel single-flight (plan 003).

## Current state

`Sources/GraphicalEngine/RunEngine.swift`:

```swift
public func cancel() async throws {
    cancelRequested = true
    if var run = currentRun {
        run.status = .cancelled
        // ... saveRun + trace
    }
}
```

In `executeFrom`, `cancelRequested` is checked at loop entry (`for iteration`) but **not** after `cli.invoke` (~line 283). Success/fail paths then `saveRun` with new statuses.

`Sources/GraphicalCLI/ProcessRunner.swift` — `ProcessExecuting.run(...)` has timeout kill via `process.terminate()`, but **no** external cancellation API. `Process` is local to `run`.

Convention: engine tests use temp dirs + `TraceStore(inMemory: true)` — see `Tests/GraphicalEngineTests/RunEngineTests.swift` `testVerticalSliceWithApproval`.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `./scripts/test.sh` or `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test` | exit 0 |
| Build | `swift build` (with DEVELOPER_DIR) | exit 0 |

## Scope

**In scope**:
- `Sources/GraphicalCLI/ProcessRunner.swift` (protocol + implementation)
- `Sources/GraphicalEngine/RunEngine.swift`
- `Sources/GraphicalEngine/DoneCheckEvaluator.swift` only if needed to pass a cancel token (prefer not)
- `Tests/GraphicalEngineTests/RunEngineTests.swift` (or new `CancelTests.swift`)
- Fake process runner used by tests if present / new fake

**Out of scope**:
- `AppModel` (plan 003)
- Trace redaction (011)
- Template escaping (010)

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Add cancellation to ProcessExecuting

Extend the protocol so callers can cancel an in-flight process. Preferred minimal API:

Option A (recommended): pass a `CancellationToken` / use `Task.checkCancellation()` + store the current `Process` on the runner actor/class under a lock, with `func cancelCurrent()`.

Option B: change `run` to accept an optional `AtomicBool` / `OSAllocatedUnfairLock<Bool>` `cancelFlag` polled in the wait loop alongside the timeout.

Pick **one** and document it in a short comment on the protocol. Ensure:

- On cancel: `terminate()` then escalate like timeout path.
- `ProcessResult.timedOut` stays for timeouts; either reuse it or add `cancelled: Bool` — if you add a field, update all call sites/tests.

**Verify**: `swift build` exits 0.

### Step 2: Wire RunEngine cancel into CLI invoke

In `RunEngine`:

1. Keep setting `cancelRequested = true` and persisting `.cancelled` in `cancel()`.
2. After **every** `await` that can take time (`cli.invoke`, and check evaluation if it shells), if `cancelRequested` { throw `RunEngineError.cancelled` **without** changing status away from `.cancelled` }.
3. Before any `saveRun` that sets `.running` / `.failed` / `.succeeded`, if `cancelRequested` or `currentRun?.status == .cancelled`, throw/return without overwriting cancelled.
4. When starting `cli.invoke`, ensure the process runner’s cancel hook is connected so `cancel()` also kills the child.

**Verify**: `swift build` exits 0.

### Step 3: Regression test

Add a test that:

1. Uses a fake or slow `/bin/sleep` runner (or ProcessExecuting mock that waits on a continuation).
2. Starts a run.
3. Calls `cancel()` while invoke is in flight.
4. Asserts final `currentRun?.status == .cancelled` and that after the in-flight work completes, status is **still** `.cancelled` (not succeeded/failed).

Model structure after `testVerticalSliceWithApproval` (temp dir + in-memory TraceStore).

**Verify**: `./scripts/test.sh --filter Cancel` (or full `./scripts/test.sh`) → pass.

## Test plan

- New: cancel during long invoke → stays cancelled.
- Existing vertical slice still passes.

## Done criteria

- [ ] Post-`cli.invoke` cancel check exists in `RunEngine.executeFrom`
- [ ] Cancelled status is not overwritten by later saveRun paths
- [ ] In-flight process can be terminated on cancel
- [ ] New cancel test passes; full `./scripts/test.sh` exits 0
- [ ] `plans/README.md` row 002 → DONE

## STOP conditions

- Changing `ProcessExecuting` breaks `ModelCatalog` in a way that needs API redesign beyond a cancel flag — report before large rewrite.
- No way to test without real `sleep` and race flakiness after two attempts — mark test as using a controllable fake and stop if fake injection is impossible without Engine API change outside scope.

## Maintenance notes

- Reviewers: every new `await` in the engine loop must re-check cancel.
- Plan 003 depends on “cancel is terminal” being true.
