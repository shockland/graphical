# Plan 006: Inspector preserves shell done-checks on Apply

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalApp/OrgInspectorView.swift Sources/GraphicalDomain/SeedTemplate.swift`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

The seeded implementer node uses a `.shell(...)` done-check. `OrgInspectorView.applyNode` rebuilds `done` from the artifacts text field + optional routerNext only, **dropping** shell checks. Clicking Apply silently breaks the org. Full shell/anyOf editor is a larger UX task; this plan at least makes Apply round-trip safe.

## Current state

`Sources/GraphicalApp/OrgInspectorView.swift:331-347`:

```swift
@objc private func applyNode() {
    guard currentNode != nil else { return }
    let artifacts = artifactsField.stringValue
        .split(separator: ",")
        ...
    var checks: [DoneCheck] = artifacts.map { .artifact($0) }
    if routerNextButton.state == .on { checks.append(.routerNext) }
    let node = OrgNode(
        ...
        done: .allOf(checks),
        ...
    )
    delegate?.orgInspector(self, didUpdateNode: node)
}
```

Seed implementer (see `SeedTemplate.swift`) includes shell done-checks — confirm when editing.

Domain supports `.shell`, `.artifact`, `.routerNext`, and `anyOf` / `allOf` (`Models.swift`).

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `swift build` with DEVELOPER_DIR | exit 0 |
| Test | `./scripts/test.sh` | exit 0 |

## Scope

**In scope**:
- `Sources/GraphicalApp/OrgInspectorView.swift`
- Optional pure helper in `Sources/GraphicalDomain/` e.g. `DoneCheckEditing.swift` for merge logic + unit tests
- Minimal UI: show a read-only caption listing preserved non-artifact checks, OR a text field for shell commands

**Out of scope**:
- Full `anyOf` visual editor
- Edge `pass` multi-select editor (mention as follow-up; do not implement unless trivial)
- Engine changes

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Define merge semantics (pure function)

Implement something like:

```swift
enum DoneCheckMerge {
    static func applyArtifactEdits(
        existing: DoneCheckGroup,
        artifactPaths: [String],
        includeRouterNext: Bool
    ) -> DoneCheckGroup
}
```

Rules:

1. Preserve group kind (`allOf` vs `anyOf`) from `existing`.
2. Start from existing checks; **remove** old `.artifact` checks; **insert** new artifact checks from the field (stable order: artifacts first or keep relative order — pick one and test).
3. Preserve all `.shell` checks unchanged.
4. Add/remove `.routerNext` based on the checkbox (at most one).
5. If existing was empty and user adds artifacts, use `.allOf`.

**Verify**: Domain unit tests covering: shell preserved; artifacts replaced; routerNext toggle; anyOf preserved.

### Step 2: Wire `applyNode` to the helper

Replace the rebuild-from-scratch logic with the helper using `currentNode!.done`.

**Verify**: `swift build` exits 0.

### Step 3: UI honesty

When `currentNode.done` contains `.shell` checks, show a muted label under artifacts, e.g. `Also: N shell check(s) preserved on Apply` listing the commands truncated. Optionally add a simple multiline field to edit shell commands as one-per-line — nice-to-have if small.

**Verify**: manual — open seed project, select implementer, Apply without edits, save, confirm `org.yaml` still has shell check.

### Step 4: Edge Apply must not strip `pass`

Confirm `applyEdge` already keeps `pass` (it mutates a copy of `currentEdge`). If it resets `pass`, fix. Do not add pass UI in this plan unless broken.

**Verify**: `rg -n "pass" Sources/GraphicalApp/OrgInspectorView.swift` and read `applyEdge`.

## Test plan

- Domain tests for `DoneCheckMerge` (primary).
- No AppKit UI tests required.

## Done criteria

- [ ] Apply on implementer seed node preserves shell checks
- [ ] Domain tests for merge helper pass
- [ ] `./scripts/test.sh` exits 0
- [ ] `plans/README.md` row 006 → DONE

## STOP conditions

- `DoneCheckGroup` encoding makes preserve impossible without model change — STOP and report.
- Product owner wants full shell editor before merge helper — still land helper first; editor can wrap it.

## Maintenance notes

- Future full editor should call the same merge/replace APIs.
- Plan 015 should remove the “Apply drops shell checks” warning once this lands.
