# Plan 007: Reject empty done-check groups

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalDomain/OrgValidator.swift Sources/GraphicalEngine/DoneCheckEvaluator.swift Sources/GraphicalDomain/Models.swift`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

`allOf([])` uses `allSatisfy` → true; `anyOf([])` treats empty as success. A node with empty done checks passes after one CLI iteration and can advance or terminate the run without proving outputs. `OrgNode` defaults to `.allOf([])`. Validator does not catch this.

## Current state

`DoneCheckEvaluator.swift:30-36`:

```swift
case .allOf:
    passed = results.allSatisfy(\.passed)
case .anyOf:
    passed = results.contains(where: \.passed) || results.isEmpty
```

`OrgValidator` issue enum has no empty-done case (`OrgValidator.swift:3-13`).

`AppModel.addNode` creates nodes with `.artifact("output.md")` — good — but YAML can still load empty groups.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `./scripts/test.sh` | exit 0 |

## Scope

**In scope**:
- `Sources/GraphicalDomain/OrgValidator.swift`
- Optionally harden evaluator to fail closed on empty (belt and suspenders)
- Tests in `Tests/GraphicalDomainTests/`

**Out of scope**:
- Inspector UX for empty groups (006)
- Changing default `OrgNode` init signature unless needed for compile

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Add validation issue

Add `case emptyDoneChecks(nodeId: String)` with a clear message. In `validate`, for each node, if `node.done.checks.isEmpty`, append the issue.

**Verify**: unit test — empty done → issue; seed template → no empty-done issues.

### Step 2 (optional but recommended): Fail closed in evaluator

If `checks.isEmpty`, return `(passed: false, results: [CheckResult(name: "done", passed: false, detail: "Empty done-check group")])`.

**Verify**: small evaluator test.

### Step 3: Confirm RunEngine still blocks on validation

`RunEngine.start` already throws on org validation issues. `AppModel.startRun` blocks on `validationIssues`. No change needed if empty done surfaces in validator.

**Verify**: `./scripts/test.sh` exits 0.

## Test plan

- Validator: empty allOf / anyOf flagged
- Seed org remains valid
- Evaluator empty → not passed (if Step 2 done)

## Done criteria

- [ ] Empty done groups are validation errors
- [ ] Tests cover the new issue
- [ ] `./scripts/test.sh` exits 0
- [ ] `plans/README.md` row 007 → DONE

## STOP conditions

- A deliberate “terminal stub” node in seed relies on empty done — none today; if found, give it an explicit artifact check instead of allowing empty.

## Maintenance notes

- Reviewers: keep validator and evaluator consistent (fail closed).
