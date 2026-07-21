import Foundation

/// Which org graph `YAMLStore.createProject` writes under `.graphical/`.
public enum ProjectSeedTemplate: Equatable, Sendable {
    case none
    case plannerImplementerReviewer
    /// Fan-out → `meshWidth` Planner→Interpreter lanes → join → Auditor → Implementer → Report.
    case agenticMesh
}

public enum SeedTemplate {
    /// Planner (router) → Implementer → Reviewer with optional approval before implementer.
    ///
    /// The no-argument form intentionally preserves the original `echo_fixture` demo,
    /// including its inert Claude-style model labels. When a runner kind is supplied,
    /// those labels are retained only for Claude Code, where they are valid aliases.
    public static func plannerImplementerReviewer(
        runnerName: String = "echo_fixture",
        agentKind: AgentKind? = nil
    ) -> OrgGraph {
        let preserveClaudeModels = agentKind == nil || agentKind == .claudeCode
        let planner = OrgNode(
            id: "planner",
            role: "Planner",
            runner: runnerName,
            model: preserveClaudeModels ? "opus" : nil,
            instructions: """
            You are the Planner. Produce plan.md with a short implementation plan.
            Then write next.json choosing the next hop (usually implementer).
            """,
            done: .allOf([
                .artifact("plan.md"),
                .routerNext
            ]),
            maxIterations: 3,
            timeoutSeconds: 30
        )

        let implementer = OrgNode(
            id: "implementer",
            role: "Implementer",
            runner: runnerName,
            model: preserveClaudeModels ? "sonnet" : nil,
            instructions: """
            You are the Implementer. Follow plan.md and produce implementation.md.
            Ensure the shell check passes.
            """,
            done: .allOf([
                .artifact("implementation.md"),
                .shell("test -f implementation.md")
            ]),
            maxIterations: 5,
            timeoutSeconds: 30
        )

        let reviewer = OrgNode(
            id: "reviewer",
            role: "Reviewer",
            runner: runnerName,
            model: preserveClaudeModels ? "fable" : nil,
            instructions: """
            You are the Reviewer. Produce review.md with approve or reject notes.
            """,
            done: .allOf([
                .artifact("review.md")
            ]),
            maxIterations: 3,
            timeoutSeconds: 30
        )

        let edges = [
            OrgEdge(
                id: "planner-router",
                from: "planner",
                type: .router,
                targets: ["implementer", "reviewer"],
                on: .success,
                pass: [.summary, .artifacts, .checks, .next],
                requiresApproval: true
            ),
            OrgEdge(
                id: "implementer-to-reviewer",
                from: "implementer",
                to: "reviewer",
                type: .fixed,
                on: .success,
                pass: [.summary, .artifacts, .checks],
                requiresApproval: false
            ),
            OrgEdge(
                id: "reviewer-reject-to-implementer",
                from: "reviewer",
                to: "implementer",
                type: .fixed,
                on: .reject,
                pass: [.summary, .artifacts, .checks, .notes],
                requiresApproval: false
            )
        ]

        return OrgGraph(nodes: [planner, implementer, reviewer], edges: edges, entry: "planner")
    }

    /// Fan-out → `X` Planner→Interpreter lanes → join → Auditor → Implementer → Report.
    /// Width is static after seed; change `X` by re-seeding (`ProjectConfig.meshWidth`).
    ///
    /// Seed model policy is nil-inherit: per-node `model` stays `nil` so each node uses its
    /// runner's `defaultModel`. Distinct planner models come from user configuration, not
    /// hard-coded seed ladders. (`agentKind` is retained for call-site compatibility.)
    public static func agenticMesh(
        width: Int,
        runnerName: String = "echo_fixture",
        agentKind: AgentKind? = nil
    ) -> OrgGraph {
        let w = max(OrgValidator.minMeshWidth, min(OrgValidator.maxMeshWidth, width))
        _ = agentKind

        let entry = OrgNode(
            id: "entry",
            role: "Coordinator",
            runner: runnerName,
            model: nil,
            instructions: """
            You are the mesh coordinator. Confirm the goal is ready, then write summary.txt.
            Fan-out will activate all planner lanes.
            """,
            done: .allOf([.artifact("summary.txt")]),
            maxIterations: 1,
            timeoutSeconds: 30
        )

        var nodes: [OrgNode] = [entry]
        var edges: [OrgEdge] = []
        var plannerIds: [String] = []

        for i in 1...w {
            let plannerId = "planner-\(i)"
            plannerIds.append(plannerId)
            nodes.append(
                OrgNode(
                    id: plannerId,
                    role: "Planner",
                    runner: runnerName,
                    model: nil,
                    instructions: """
                    You are Planner lane \(i) of \(w). You have your own coding tool and model \
                    (configured on this node). Read the goal and produce plan.md with your approach.
                    Also write summary.txt with exactly one sentence summarizing the plan for your \
                    paired interpreter. Do not coordinate with other planner lanes.
                    """,
                    done: .allOf([.artifact("plan.md"), .artifact("summary.txt")]),
                    maxIterations: 3,
                    timeoutSeconds: 30
                )
            )
            let interpreterId = "interpreter-\(i)"
            nodes.append(
                OrgNode(
                    id: interpreterId,
                    role: "Interpreter",
                    runner: runnerName,
                    model: nil,
                    instructions: """
                    You are Interpreter lane \(i) of \(w). Read inbound plan.md from your paired \
                    planner. Extract goals — do not re-plan.
                    Produce interpretation.md with these required sections:
                    - Plan goals (numbered list)
                    - Approach summary
                    - Risks / conflicts for auditor
                    Write summary.txt as one line stating the goal count (e.g. "3 goals extracted").
                    """,
                    done: .allOf([.artifact("interpretation.md"), .artifact("summary.txt")]),
                    maxIterations: 3,
                    timeoutSeconds: 30
                )
            )
            edges.append(
                OrgEdge(
                    id: "\(plannerId)-to-\(interpreterId)",
                    from: plannerId,
                    to: interpreterId,
                    type: .fixed,
                    on: .success,
                    pass: [.summary, .artifacts, .checks]
                )
            )
            edges.append(
                OrgEdge(
                    id: "\(interpreterId)-join-auditor",
                    from: interpreterId,
                    to: "auditor",
                    type: .join,
                    on: .success,
                    pass: [.summary, .artifacts, .checks]
                )
            )
        }

        edges.insert(
            OrgEdge(
                id: "entry-fanout",
                from: "entry",
                type: .fanOut,
                targets: plannerIds,
                on: .success,
                pass: [.summary, .artifacts, .checks]
            ),
            at: 0
        )

        nodes.append(
            OrgNode(
                id: "auditor",
                role: "Auditor",
                runner: runnerName,
                model: nil,
                instructions: """
                You are the Auditor. Read every interpreter inbound handoff (interpretation.md).
                Merge procedure: dedupe goals, resolve conflicts with recorded rationale, order by \
                dependency, then emit one final-plan.md with these required sections:
                - Summary
                - Merged Objectives
                - Implementation Phases
                - Acceptance Criteria
                - Constraints
                - Conflicts Resolved
                - Out of Scope
                Write summary.txt naming the chosen plan only (final plan for the implementer).
                """,
                done: .allOf([.artifact("final-plan.md"), .artifact("summary.txt")]),
                maxIterations: 3,
                timeoutSeconds: 30
            )
        )
        nodes.append(
            OrgNode(
                id: "implementer",
                role: "Implementer",
                runner: runnerName,
                model: nil,
                instructions: """
                You are the Implementer. Follow the auditor's final-plan.md and produce implementation.md.
                There is a single implementer for the mesh; execute the merged plan only.
                """,
                done: .allOf([
                    .artifact("implementation.md"),
                    .shell("test -f implementation.md")
                ]),
                maxIterations: 5,
                timeoutSeconds: 30
            )
        )
        nodes.append(
            OrgNode(
                id: "report",
                role: "Report",
                runner: runnerName,
                model: nil,
                instructions: """
                You are Report. Produce report.md summarizing the mesh run outcome.
                """,
                done: .allOf([.artifact("report.md")]),
                maxIterations: 2,
                timeoutSeconds: 30
            )
        )

        edges.append(
            OrgEdge(
                id: "auditor-to-implementer",
                from: "auditor",
                to: "implementer",
                type: .fixed,
                on: .success,
                pass: [.summary, .artifacts, .checks],
                requiresApproval: true
            )
        )
        edges.append(
            OrgEdge(
                id: "implementer-to-report",
                from: "implementer",
                to: "report",
                type: .fixed,
                on: .success,
                pass: [.summary, .artifacts, .checks]
            )
        )

        return OrgGraph(nodes: nodes, edges: edges, entry: "entry")
    }

    public static func defaultRunners() -> RunnersConfig {
        RunnersConfig(runners: [
            "echo_fixture": RunnerTemplate(
                command: "/bin/bash",
                args: [
                    "-lc",
                    """
                    set -euo pipefail
                    PACKET={{prompt_file}}
                    OUT={{node_artifacts}}
                    mkdir -p "$OUT"
                    ROLE=$(basename "$OUT")
                    case "$ROLE" in
                      entry)
                        echo "Mesh ready." > "$OUT/summary.txt"
                        ;;
                      planner|planner-*)
                        echo "# Plan" > "$OUT/plan.md"
                        echo "Implement the goal in small steps." >> "$OUT/plan.md"
                        echo "Planner lane ready." > "$OUT/summary.txt"
                        if [[ "$ROLE" == "planner" ]]; then
                          printf '%s\\n' '{"node_id":"implementer","reason":"Plan ready for implementation"}' > "$OUT/next.json"
                        fi
                        ;;
                      interpreter|interpreter-*)
                        echo "# Interpretation" > "$OUT/interpretation.md"
                        echo "Refined attack plan." >> "$OUT/interpretation.md"
                        echo "Interpreter lane ready." > "$OUT/summary.txt"
                        ;;
                      auditor)
                        echo "# Final Plan" > "$OUT/final-plan.md"
                        echo "Synthesized from all interpreter lanes." >> "$OUT/final-plan.md"
                        echo "Auditor chose the final plan." > "$OUT/summary.txt"
                        ;;
                      implementer)
                        echo "# Implementation" > "$OUT/implementation.md"
                        echo "Done." >> "$OUT/implementation.md"
                        echo "Implementation complete." > "$OUT/summary.txt"
                        ;;
                      report)
                        echo "# Report" > "$OUT/report.md"
                        echo "Mesh run complete." >> "$OUT/report.md"
                        ;;
                      reviewer)
                        echo "# Review" > "$OUT/review.md"
                        echo "Approved." >> "$OUT/review.md"
                        ;;
                      *)
                        echo "# Output" > "$OUT/output.md"
                        ;;
                    esac
                    echo "Fixture runner completed for $ROLE (packet: $PACKET)"
                    """
                ],
                cwd: "{{project_root}}",
                env: [:],
                kind: .custom,
                defaultModel: nil
            ),
            "claude_code": RunnerTemplate(
                command: "claude",
                args: ["-p", "{{prompt_file}}", "--model", "{{model}}"],
                cwd: "{{project_root}}",
                env: [:],
                kind: .claudeCode,
                defaultModel: "sonnet"
            ),
            "cursor_agent": RunnerTemplate(
                command: "/bin/bash",
                args: [
                    "-lc",
                    """
                    set -euo pipefail
                    export PATH="$HOME/.local/bin:$PATH"
                    cursor-agent -p --output-format stream-json --stream-partial-output --trust --force --workspace {{project_root}} --model {{model}} "$(cat {{prompt_file}})"
                    """
                ],
                cwd: "{{project_root}}",
                env: [:],
                kind: .cursorAgent,
                defaultModel: "composer-2.5-fast"
            )
        ])
    }
}
