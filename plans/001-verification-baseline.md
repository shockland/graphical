# Plan 001: Verification baseline (AGENTS + test script + CI)

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If a STOP condition occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat dbefb74..HEAD -- README.md Package.swift .github scripts AGENTS.md`
> If any in-scope path changed since `dbefb74`, compare Current state against live files before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `dbefb74`, 2026-07-20

## Why this matters

`swift test` fails with `no such module 'XCTest'` under Command Line Tools alone; the README already documents needing Xcode’s `DEVELOPER_DIR`, but there is no wrapper script, no `AGENTS.md`, and no CI. Agents and humans get a false “tests are broken” signal. Every later plan’s done criteria depend on a reliable test command.

## Current state

- `README.md:33-38` — documents:
  ```bash
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  swift test
  ```
- `Package.swift:49-60` — test targets `GraphicalDomainTests`, `GraphicalEngineTests` exist.
- No `.github/workflows/`, no `scripts/`, no `AGENTS.md`.
- Repo is a small SPM AppKit app: targets Domain / CLI / Engine / App.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build` | exit 0 |
| Tests (via script after Step 2) | `./scripts/test.sh` | exit 0, tests pass |
| Tests (direct) | `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test` | exit 0 |

## Scope

**In scope**:
- `AGENTS.md` (create)
- `scripts/test.sh` (create)
- `.github/workflows/test.yml` (create)
- `README.md` (link to script; keep accurate)

**Out of scope**:
- Product / engine / app Swift source
- Changing Package.swift dependencies
- SwiftLint / formatters

## Git workflow

- Stay on the **current branch**. Do **not** create a worktree.
- Do not push or open a PR unless the operator asks.
- Commit only if the operator asks. Message style from history: short imperative (`wip`, `First Pass`). Prefer: `Add AGENTS.md, test script, and CI`.

## Steps

### Step 1: Create `AGENTS.md`

Create `/Users/chris/Projects/Graphical/AGENTS.md` with at least:

- macOS 14+, Xcode required for tests
- Always `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before `swift build` / `swift test`
- Target map: `GraphicalDomain` → `GraphicalCLI` → `GraphicalEngine` → `GraphicalApp`
- Prefer tests in Domain/Engine; avoid AppKit in unit tests
- Skip editing `.build/`, `.graphical/artifacts/`
- Point to `./scripts/test.sh`
- Note plans live in `plans/`

**Verify**: `test -f AGENTS.md && rg -n "DEVELOPER_DIR|scripts/test" AGENTS.md` → matches exist.

### Step 2: Create `scripts/test.sh`

Executable bash script that:

1. If `/Applications/Xcode.app/Contents/Developer` exists, export `DEVELOPER_DIR` to it (unless already set).
2. If `xcrun --find xctest` fails, print a clear error (“need full Xcode, not CLT”) and exit 1.
3. `cd` to repo root (script-relative).
4. Run `swift test` and exit with its status.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --find xctest >/dev/null 2>&1; then
  echo "error: XCTest not found. Install Xcode and set DEVELOPER_DIR." >&2
  exit 1
fi
exec swift test "$@"
```

`chmod +x scripts/test.sh`

**Verify**: `./scripts/test.sh` → exit 0 (with Xcode installed).

### Step 3: Add GitHub Actions workflow

Create `.github/workflows/test.yml`:

- `on: [push, pull_request]`
- `runs-on: macos-14` (or `macos-15` if available)
- steps: checkout; set `DEVELOPER_DIR`; `swift test`
- Keep it short — no caching required for this package size.

**Verify**: `test -f .github/workflows/test.yml && rg -n "swift test" .github/workflows/test.yml` → match.

### Step 4: Touch README

In the Tests section of `README.md`, add one line pointing to `./scripts/test.sh` as the preferred entry point. Replace the absolute `cd /Users/chris/Projects/Graphical` with a relative `cd` (repo root). Do not rewrite the whole README (plan 015 owns deeper doc honesty).

**Verify**: `rg -n "scripts/test|Users/chris/Projects/Graphical" README.md` → script mentioned; absolute personal path gone (or only in historical comments — prefer gone).

## Test plan

- No new Swift tests. Verification is `./scripts/test.sh` green.

## Done criteria

- [ ] `AGENTS.md` exists and mentions DEVELOPER_DIR + target map
- [ ] `./scripts/test.sh` exits 0
- [ ] `.github/workflows/test.yml` exists and runs `swift test`
- [ ] README points at the script; no machine-specific `cd` path
- [ ] No product Swift files modified (`git status`)
- [ ] `plans/README.md` row 001 → DONE

## STOP conditions

- Xcode is not installed on the machine and you cannot run tests — document BLOCKED; still land script + AGENTS + workflow.
- Operator forbids creating `.github/` — land script + AGENTS only and mark CI step REJECTED in the index note.

## Maintenance notes

- When bumping macOS/Xcode in CI images, update both README and the workflow.
- Agents should always prefer `./scripts/test.sh` over raw `swift test`.
