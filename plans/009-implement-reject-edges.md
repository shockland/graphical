# Plan 009: Implement `on: reject` edge routing

> **Executor instructions**: This is a **design-then-build** plan. Complete the design checklist in Step 1 and write the decision into this file (or `plans/009-decision.md`) before coding. Follow steps. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalEngine/RunEngine.swift Sources/GraphicalDomain/SeedTemplate.swift Sources/GraphicalDomain/Models.swift Tests/GraphicalEngineTests/`

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: plans/007-reject-empty-done-groups.md, plans/008-retry-preserve-inbound.md
- **Category**: direction
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

The seed org includes `reviewer-reject-to-implementer` with `on: .reject`, and the inspector exposes On=reject. The engine **never** follows reject edges: after success it only considers `.success`/`.always`; if none, the node is terminal success. Approval UI “Reject” fails the whole run. The advertised planner→implementer→reviewer loop cannot send work back.

## Current state

Seed edge (`SeedTemplate.swift:74-82`):

```swift
OrgEdge(
    id: "reviewer-reject-to-implementer",
    from: "reviewer",
    to: "implementer",
    type: .fixed,
    on: .reject,
    pass: [.summary, .artifacts, .checks, .notes],
    requiresApproval: false
)
```

`RunEngine` success path (~386): filters `on == .success || .always` only. Fail path (~333) looks for `on == .fail` only. `rejectApproval` (~156) sets run `.failed`.

**Do not confuse** edge condition `.reject` with approval-gate rejection.

## Recommended product decision (default — executor should use unless operator overrides)

**Signal for node-level reject:** Reviewer writes `next.json` is **not** required. Prefer:

1. If the node’s done-checks **pass** and an artifact `decision.txt` (or `summary.txt`) contains a first-line token `REJECT` / `APPROVE` — too magical.

**Cleaner default:**

- Add optional done-check or convention: artifact `review.md` exists (already) **and** artifact `reject` (empty marker file) means take reject edges; absence means success edges.
- Or: shell check that exits 0 for approve path… awkward.

**Chosen default for this plan (implement this unless STOP):**

After done-checks **pass**, look for file `nodeArtifacts/reject.json` with shape `{"reject": true, "reason": "..."}`.  

- If present and `reject == true` → select outgoing edges with `on == .reject` (else `.fail` fallback? **no** — only `.reject`). If none, fail the run with a clear error.
- If absent → existing success/always routing.
- Approval-gate Reject remains “fail run” **or** (stretch) if a reject edge exists from the **from** node, follow it — **out of scope**; keep approval Reject = fail run; document.

Write this decision at the top of the implementation PR / in `plans/009-decision.md`.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `./scripts/test.sh` | exit 0 |

## Scope

**In scope**:
- `RunEngine.swift` routing after successful done-checks
- `WorkingPacket.swift` — mention reject.json convention in packet text
- Seed fixture runner: reviewer case can optionally emit reject in a **new test-only** runner, not necessarily change default seed happy path
- Tests for reject routing
- README note deferred to plan 015

**Out of scope**:
- Reworking approval Reject to mean edge reject
- Full inspector for reject.json
- Changing `EdgeCondition` enum cases

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Freeze the decision

Create `plans/009-decision.md` with the reject signal (`reject.json`), approval-Reject behavior (fail run), and max reject-loop iterations note (use existing node `maxIterations` only; no new global counter unless infinite loops appear — if A→B→A via reject, rely on maxIterations per visit).

**Verify**: file exists and states the three bullets.

### Step 2: Implement routing branch

After done-checks pass and before selecting success edges:

```swift
if let reject = loadReject(from: nodeArtifacts), reject.reject {
   // build contract with notes = reason
   // find on == .reject edges (fixed/router rules analogous to success)
   // handoff to destination
   return
}
```

If reject signaled but no reject edge → `RunEngineError.failed("…")`.

**Verify**: `swift build` exits 0.

### Step 3: Tests

1. Org: reviewer success edge to end **and** reject edge to implementer. Runner for reviewer writes `reject.json` → assert next active/executed node is implementer (or handoff events).
2. Happy path without reject.json still succeeds as today (vertical slice).
3. reject.json without reject edge → failed with clear error.

**Verify**: `./scripts/test.sh` exits 0.

### Step 4: Packet docs

In `WorkingPacketBuilder`, add a short line under outputs: optional `reject.json` with `{"reject":true,"reason":"..."}` to take reject edges.

**Verify**: string present in built packet in a unit test or snapshot assert.

## Test plan

As Step 3. Model after `RunEngineTests.testVerticalSliceWithApproval`.

## Done criteria

- [ ] `plans/009-decision.md` exists
- [ ] Reject signal routes via `on: .reject` edges
- [ ] Seed happy path still succeeds without reject.json
- [ ] Tests cover reject + missing edge + happy path
- [ ] `./scripts/test.sh` exits 0
- [ ] `plans/README.md` row 009 → DONE

## STOP conditions

- Operator prefers **deleting** reject edges from seed instead of implementing — do that smaller change, mark this plan REJECTED with note, and update seed + inspector to hide reject.
- Infinite ping-pong without bound after two test attempts — add a run-level reject hop counter (max 8) and document.
- Design conflict with router edges on reject — STOP and report; do not invent router-reject without decision update.

## Maintenance notes

- Approval Reject ≠ edge reject; keep names distinct in UI copy later.
- Plan 015 documents the `reject.json` convention.
