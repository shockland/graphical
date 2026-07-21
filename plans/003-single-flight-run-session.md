# Plan 003: Single-flight run session (AppModel)

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalApp/AppModel.swift Sources/GraphicalApp/RunConsoleController.swift`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/002-reliable-cancel.md
- **Category**: bug
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

Even with `runSession` guards (possible uncommitted WIP), `cancelRun()` sets `isRunning = false` as soon as `engine.cancel()` returns, while the original `start`/`approve`/`retry` Task may still be inside `executeFrom`. Play can then start a second `RunEngine`. Approve/retry are not gated on `isRunning`. `loadRun` event fetches have no generation token and can clobber Trace events.

## Current state (as of audit; WIP may differ)

`Sources/GraphicalApp/AppModel.swift`:

- `startRun` may already bump `runSession` and gate on `isRunning` / `pendingApproval`.
- `cancelRun` still clears `isRunning` immediately after `await engine.cancel()` — **wrong** until the owning Task exits.
- `approve()` / `retryRun()` set `isRunning = true` but do not refuse if another Task is already active.
- `loadRun`:

```swift
func loadRun(_ run: RunRecord) {
    self.run = run
    selectedTab = .trace
    notify()
    Task {
        events = try await traceStore?.events(runId: run.id) ?? []
        notify()
    }
}
```

`RunConsoleController.reload` — Play disabled when running / pending; Retry may still be enabled during runs.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build` | exit 0 |
| Test | `./scripts/test.sh` | exit 0 |

## Scope

**In scope**:
- `Sources/GraphicalApp/AppModel.swift`
- `Sources/GraphicalApp/RunConsoleController.swift`
- Optional: extract a tiny pure helper + unit test under Domain/Engine **only if** needed; prefer no new AppKit tests

**Out of scope**:
- Engine cancel internals (plan 002)
- Progress UI scoping (plan 013)
- Full AppModel architecture split

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Track an in-flight run Task

In `AppModel`, introduce a single owner for async run work, e.g.:

- `private var runTask: Task<Void, Never>?`
- Or keep `runSession` and add `private var engineBusy = false` that is true from Task start until Task exit (including after cancel).

Rules:

1. `startRun` / `approve` / `retryRun` must refuse (set statusMessage) if a run Task is still active — not merely if `isRunning` is true.
2. `cancelRun` calls `engine.cancel()` but **does not** set `isRunning = false` itself; the owning Task clears `isRunning` / `engineBusy` in its `defer` / end.
3. `closeProject` bumps session / cancels and waits or abandons with session bump so stale Tasks no-op (WIP may already bump `runSession`).

**Verify**: `swift build` exits 0.

### Step 2: Gate Retry / Approve in UI + model

- Model: `retryRun` only if `run?.status` is `.failed` or `.cancelled` and not busy; `approve` only if `pendingApproval != nil` and not busy.
- UI: disable Retry unless those statuses; disable Approve/Reject appropriately in `RunConsoleController.reload`.

**Verify**: `swift build` exits 0.

### Step 3: Fix `loadRun` races

Capture `let id = run.id` (or `loadGeneration += 1`) in the Task; apply `events` only if `self.run?.id == id` (and generation matches).

**Verify**: `swift build` exits 0.

### Step 4: Manual checklist (no AppKit test harness)

Document in the PR/plan completion note:

1. Start a slow run (sleep-based runner or long agent).
2. Hit Cancel — Play stays disabled until status settles; no second overlapping run.
3. Rapidly click recent runs in the rail — Trace events match selected id.

**Verify**: `./scripts/test.sh` still exits 0 (no regressions).

## Test plan

- Prefer engine-level coverage from plan 002.
- If you extract a pure “shouldAllowStart/Approve/Retry(state)” helper into Domain, unit-test it; otherwise rely on build + manual checklist.

## Done criteria

- [ ] `isRunning` / busy cleared only when the owning Task finishes
- [ ] Cancel does not enable Play while engine still executing
- [ ] Approve/retry/start refuse when busy
- [ ] `loadRun` cannot apply stale events
- [ ] `swift build` + `./scripts/test.sh` exit 0
- [ ] `plans/README.md` row 003 → DONE

## STOP conditions

- Uncommitted WIP conflicts with this design — merge behaviors carefully; do not delete session guards without replacement.
- Requires rewriting `MainWindowController` — STOP; keep changes in AppModel + RunConsole.

## Maintenance notes

- Reviewers: search for `isRunning = false` — only the Task exit path (and closeProject reset) should clear it.
- Plan 013 assumes notify storms are separate from session correctness.
