# Plan 004: Path confinement for artifacts, goalFile, and nodeId

> **Executor instructions**: Follow step by step. Verify each step. On STOP, report. Update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- Sources/GraphicalEngine/DoneCheckEvaluator.swift Sources/GraphicalDomain/YAMLStore.swift Sources/GraphicalDomain/OrgValidator.swift Sources/GraphicalDomain/Models.swift`

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-verification-baseline.md
- **Category**: security
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

Artifact done-checks use `appendingPathComponent(relativePath)` with no containment check, so `../…` can escape the node artifacts directory. `goalFile` is written the same way under the project root. `nodeId` is used as a path component when creating artifact dirs. Hand-edited YAML can read/write outside intended trees.

## Current state

`Sources/GraphicalEngine/DoneCheckEvaluator.swift:47-50`:

```swift
case .artifact(let relativePath):
    let url = nodeArtifacts.appendingPathComponent(relativePath)
```

`Sources/GraphicalDomain/YAMLStore.swift:175-180`:

```swift
private func ensureGoalFile(projectRoot: URL, config: ProjectConfig) throws {
    guard let goalFile = config.goalFile else { return }
    let url = projectRoot.appendingPathComponent(goalFile)
    // writes without confinement
}
```

`RunEngine` creates `GraphicalPaths.nodeArtifacts(..., nodeId:)` — confirm in `Models.swift` / path helpers.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Test | `./scripts/test.sh` | exit 0 |
| Build | `swift build` with DEVELOPER_DIR | exit 0 |

## Scope

**In scope**:
- New small helper e.g. `Sources/GraphicalDomain/PathSafety.swift` (or add to existing domain file)
- `DoneCheckEvaluator.swift`
- `YAMLStore.swift` (`ensureGoalFile`)
- `OrgValidator.swift` — reject unsafe `node.id` characters / `..`
- Tests under `Tests/GraphicalDomainTests/` and/or `GraphicalEngineTests/`

**Out of scope**:
- Template shell escaping (010)
- Process env (005)
- Changing artifact directory layout

## Git workflow

Stay on current branch; no worktree. Commit only if asked.

## Steps

### Step 1: Add `PathSafety` helper

Pure functions in Domain, e.g.:

- `static func resolveContained(base: URL, relative: String) -> URL?`  
  - Reject absolute paths, empty, null bytes.  
  - Resolve with `standardizedFileURL` (or `resolvingSymlinksInPath` carefully — prefer standardize without following attacker-controlled symlinks if possible).  
  - Require `result.path.hasPrefix(base.standardizedFileURL.path + "/")` or equality for files under base.
- `static func isSafeNodeId(_ id: String) -> Bool` — allowlist e.g. `[A-Za-z0-9._-]+`, reject `..`, `/`, `\`.

**Verify**: unit tests in DomainTests for: `ok`, `../escape`, absolute path, `node/../x`, safe/unsafe node ids.

### Step 2: Use in DoneCheckEvaluator

On artifact check, if resolve fails → `CheckResult(passed: false, detail: "Path escapes node artifacts")`.

**Verify**: engine or domain test with temp dirs.

### Step 3: Use in YAMLStore.ensureGoalFile

If `goalFile` escapes `projectRoot`, throw a typed `YAMLStoreError` (add case if needed).

**Verify**: Domain test.

### Step 4: OrgValidator node ids

Append issue for unsafe node ids (new enum case or reuse message). Do not break existing seed ids (`planner`, `implementer`, `reviewer`).

**Verify**: `./scripts/test.sh` + validator unit test; seed project still validates clean.

## Test plan

- Contained path OK
- `../` rejected
- Absolute rejected
- Unsafe node id rejected; seed template validates

## Done criteria

- [ ] Helper exists and is used by evaluator + goalFile write
- [ ] Node ids validated
- [ ] `./scripts/test.sh` exits 0 with new tests
- [ ] `plans/README.md` row 004 → DONE

## STOP conditions

- Symlink policy unclear on macOS for projects on network volumes — prefer standardize without symlink follow; if that breaks legitimate layouts, STOP and report.
- Seed or fixtures use ids that fail the allowlist — widen allowlist only with evidence, do not disable checks.

## Maintenance notes

- Any new path join of user/YAML strings must go through `PathSafety`.
- Reviewers: ensure error messages do not include unrelated filesystem contents beyond the attempted path.
