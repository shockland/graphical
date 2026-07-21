# Plan 008: Retry preserves inbound handoff

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalEngine/RunEngine.swift Sources/GraphicalEngine/WorkingPacket.swift Tests/GraphicalEngineTests/`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/002-reliable-cancel.md
- **Category**: bug
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

`retryActiveNode` always calls `executeFrom(..., inbound: nil, ...)`. `pausedInbound` is stored on approval pause but never read. Retrying a mid-graph node drops prior summary/artifacts from the working packet, so agents fail for the wrong reason.

## Current state

`RunEngine.swift:187-200`:

```swift
public func retryActiveNode() async throws {
    ...
    try await executeFrom(nodeId: nodeId, inbound: nil, run: &run, project: project)
}
```

`pausedInbound` set at handoff approval (~489), cleared on approve/reject/start, never passed into executeFrom.

`WorkingPacket.swift` includes inbound summary/artifacts only when inbound non-nil.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `./scripts/test.sh` | exit 0 |

## Scope

**In scope**:
- `Sources/GraphicalEngine/RunEngine.swift`
- Tests in `Tests/GraphicalEngineTests/`
- Optionally persist last inbound on the run record if needed for durability across app relaunch — **only if** in-memory is insufficient for the test; prefer in-memory `lastInbound` first

**Out of scope**:
- Reject edge routing (009)
- AppModel retry button UI (003 may already gate it)

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Track last applied inbound

Rename/clarify `pausedInbound` → keep approval pause semantics **and** add `lastInboundByNode: [String: HandoffContract]` (or single `lastInbound` for active node).

On every successful entry to `executeFrom` with a non-nil inbound, store it keyed by `nodeId`.
On approval pause, continue storing the filtered contract (existing behavior).
On `start`, clear the map.

### Step 2: Retry uses stored inbound

```swift
let inbound = lastInboundByNode[nodeId] // or pausedInbound / lastInbound
try await executeFrom(nodeId: nodeId, inbound: inbound, run: &run, project: project)
```

Entry-node retry with nil inbound remains OK.

**Verify**: `swift build` exits 0.

### Step 3: Test

Construct a two-node org (or mutate seed): first node produces summary artifact; second fails done-checks; call `retryActiveNode` on second; assert working packet file or trace/log shows inbound summary present (read `packet-*.md` under node artifacts, or spy via custom runner that writes inbound into an artifact).

Model after `testVerticalSliceWithApproval`.

**Verify**: `./scripts/test.sh` filter for the new test → pass; full suite pass.

## Test plan

- Retry after failure mid-graph retains inbound summary in packet.
- Fresh start clears inbound map.

## Done criteria

- [ ] Retry passes non-nil inbound when available
- [ ] New test passes
- [ ] `./scripts/test.sh` exits 0
- [ ] `plans/README.md` row 008 → DONE

## STOP conditions

- HandoffContract is not Codable/Sendable in a way that blocks storage — it already is used as actor state; if not, STOP.
- Need DB persistence for retry after app quit — defer to follow-up; document in Maintenance; ship in-memory first.

## Maintenance notes

- Plan 009 reject loops will retry/re-enter nodes and depend on this.
- Reviewers: ensure approve path still uses pending contract as inbound to destination (existing), and that retry of destination after later failure still has the handoff.
