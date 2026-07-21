import Foundation

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
                      planner)
                        echo "# Plan" > "$OUT/plan.md"
                        echo "Implement the goal in small steps." >> "$OUT/plan.md"
                        printf '%s\\n' '{"node_id":"implementer","reason":"Plan ready for implementation"}' > "$OUT/next.json"
                        ;;
                      implementer)
                        echo "# Implementation" > "$OUT/implementation.md"
                        echo "Done." >> "$OUT/implementation.md"
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
