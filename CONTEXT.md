# Graphical

Native macOS app for graph engineering: Org graphs of agent roles with handoff contracts that decide who runs next.

## Language

**Org graph**:
Stable roles, agents, model overrides, and handoff edges under `.graphical/`.
_Avoid_: workflow graph (UI label only), pipeline

**Work graph / Run**:
Dynamic instance of an Org graph for one goal, with node loops and traces.
_Avoid_: job, execution, pipeline run

**Node loop**:
Invoke a CLI runner until done-checks pass or the iteration budget is exhausted.

**Handoff contract**:
summary + artifacts + checks (+ router next) passed along an edge — not full transcripts.

**Reject edge**:
Outgoing edge with `on: reject` that a node can trigger via `reject.json` after done-checks pass.
_Avoid_: approval reject (Run console Reject fails an approval gate; different concept)

**Fan-out edge**:
`type: fan_out` — after the source succeeds, activate all `targets` (AND). Distinct from router (XOR via `next.json`).

**Join edge**:
`type: join` — barrier into a shared node; destination runs only when all inbound join predecessors have succeeded, with a multi-inbound handoff packet.

**Mesh width**:
`project.yaml` `meshWidth` (and Create setup “Planner lanes”) used at seed time for `SeedTemplate.agenticMesh(width:)`. New projects default to this mesh seed. Runtime does not re-expand the org; changing width re-seeds the org graph.

**Parallel fan-out**:
`project.yaml` `parallelFanOut` (default `true`; Create setup checkbox). When on, fan-out lane heads run concurrently; when off, they drain sequentially.

**Goal source**:
`GOAL.md` (or `config.goalFile`), kept in sync with `project.yaml`'s `goal` on Save.

**Node artifacts**:
Per-node directory conventions (`next.json`, `reject.json`, `summary.txt`, `packet-*`) that the engine reads and working packets instruct.

**Org editing**:
Pure mutations of the Org graph (insert/remove nodes, connect fixed/router/fan-out/join edges) shared by canvas and inspector.

**Coding tool setup**:
Applying a catalog preset: upsert the stable runner and rebind Org nodes to it, skipping Planner nodes the user has customized (non-nil model or runner ≠ shared non-planner baseline).

**Shell invocation**:
POSIX shell interpreter (`bash`/`sh`/`zsh`) with `-c`/`-lc`, whose script body must be shell-escaped when templated.

**Project session**:
Load/save, Goal source draft, Org editing, runners, and dirty tracking for an open project.

**Run session**:
Single-flight Work-graph lifecycle over `RunEngine` (start / approve / cancel / retry / traces).
