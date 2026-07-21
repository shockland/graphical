import Foundation
import GraphicalDomain

public struct AgentProbeCommand: Equatable, Sendable {
    public let command: String
    public let arguments: [String]

    public init(command: String, arguments: [String] = ["--version"]) {
        self.command = command
        self.arguments = arguments
    }
}

public struct AgentPreset: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let displayDescription: String
    public let kind: AgentKind
    public let runnerName: String
    public let defaultModel: String?
    public let probe: AgentProbeCommand?
    /// Short install/login guidance shown when the CLI is missing. Nil for Demo.
    public let installHint: String?

    private let templateFactory: @Sendable () -> RunnerTemplate

    init(
        id: String,
        displayName: String,
        displayDescription: String,
        kind: AgentKind,
        runnerName: String,
        defaultModel: String?,
        probe: AgentProbeCommand?,
        installHint: String? = nil,
        templateFactory: @escaping @Sendable () -> RunnerTemplate
    ) {
        self.id = id
        self.displayName = displayName
        self.displayDescription = displayDescription
        self.kind = kind
        self.runnerName = runnerName
        self.defaultModel = defaultModel
        self.probe = probe
        self.installHint = installHint
        self.templateFactory = templateFactory
    }

    public func makeRunnerTemplate() -> RunnerTemplate {
        templateFactory()
    }
}

public enum AgentPresetCatalogError: Error, Equatable, Sendable {
    case unknownPreset(String)
}

public enum AgentPresetCatalog {
    public static let demo = AgentPreset(
        id: "demo",
        displayName: "Demo",
        displayDescription: "Built-in fixture; no external CLI required.",
        kind: .custom,
        runnerName: "echo_fixture",
        defaultModel: nil,
        probe: nil,
        installHint: nil
    ) {
        RunnerTemplate(
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
            kind: .custom
        )
    }

    public static let claudeCode = AgentPreset(
        id: "claude-code",
        displayName: "Claude Code",
        displayDescription: "Run roles with the Claude Code CLI.",
        kind: .claudeCode,
        runnerName: "claude_code",
        defaultModel: "sonnet",
        probe: AgentProbeCommand(command: "claude"),
        installHint: "Install Claude Code and ensure `claude` is on your PATH, then sign in with `claude`."
    ) {
        RunnerTemplate(
            command: "claude",
            args: ["-p", "{{prompt_file}}", "--model", "{{model}}"],
            cwd: "{{project_root}}",
            kind: .claudeCode,
            defaultModel: "sonnet"
        )
    }

    public static let cursorAgent = AgentPreset(
        id: "cursor-agent",
        displayName: "Cursor Agent",
        displayDescription: "Run roles with Cursor's command-line agent.",
        kind: .cursorAgent,
        runnerName: "cursor_agent",
        defaultModel: "composer-2.5-fast",
        probe: AgentProbeCommand(command: "cursor-agent"),
        installHint: "Install the Cursor CLI and ensure `cursor-agent` is on your PATH."
    ) {
        RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                set -euo pipefail
                export PATH="$HOME/.local/bin:$PATH"
                cursor-agent -p --trust --force --workspace {{project_root}} --model {{model}} "$(cat {{prompt_file}})"
                """
            ],
            cwd: "{{project_root}}",
            kind: .cursorAgent,
            defaultModel: "composer-2.5-fast"
        )
    }

    public static let codex = AgentPreset(
        id: "codex",
        displayName: "Codex",
        displayDescription: "Run roles with the Codex CLI.",
        kind: .codex,
        runnerName: "codex",
        defaultModel: "gpt-5.2",
        probe: AgentProbeCommand(command: "codex"),
        installHint: "Install the Codex CLI and ensure `codex` is on your PATH, then sign in if prompted."
    ) {
        RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                set -euo pipefail
                codex exec --model {{model}} "$(cat {{prompt_file}})"
                """
            ],
            cwd: "{{project_root}}",
            kind: .codex,
            defaultModel: "gpt-5.2"
        )
    }

    public static let all: [AgentPreset] = [
        demo,
        claudeCode,
        cursorAgent,
        codex
    ]

    public static func preset(id: String) -> AgentPreset? {
        all.first { $0.id == id }
    }

    public static func preset(runnerName: String) -> AgentPreset? {
        all.first { $0.runnerName == runnerName }
    }

    /// Infers which catalog preset the project is using from node bindings.
    /// Returns a preset id when every node shares one catalog runner name,
    /// or when a majority of nodes share one. Mixed bindings with no majority
    /// return nil. Empty org falls back to a single catalog runner present in
    /// config when unambiguous.
    public static func inferredPresetID(from runners: RunnersConfig, org: OrgGraph) -> String? {
        let catalogByRunner = Dictionary(
            uniqueKeysWithValues: all.map { ($0.runnerName, $0.id) }
        )

        let boundNames = org.nodes.map(\.runner)
        if !boundNames.isEmpty {
            var counts: [String: Int] = [:]
            for name in boundNames {
                counts[name, default: 0] += 1
            }
            let sorted = counts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            guard let top = sorted.first else { return nil }
            let majorityThreshold = (boundNames.count / 2) + 1
            if top.value >= majorityThreshold, let presetID = catalogByRunner[top.key] {
                return presetID
            }
            // Unanimous non-catalog runner → nil; mixed with no majority → nil
            if top.value == boundNames.count {
                return catalogByRunner[top.key]
            }
            return nil
        }

        let matchingKeys = runners.runners.keys.filter { catalogByRunner[$0] != nil }
        if matchingKeys.count == 1, let key = matchingKeys.first {
            return catalogByRunner[key]
        }
        return nil
    }

    /// Adds or replaces the preset's stable runner key. Applying the same preset
    /// repeatedly produces the same configuration.
    public static func applying(
        presetID: String,
        to runners: RunnersConfig
    ) throws -> RunnersConfig {
        guard let preset = preset(id: presetID) else {
            throw AgentPresetCatalogError.unknownPreset(presetID)
        }
        var updated = runners
        updated.runners[preset.runnerName] = preset.makeRunnerTemplate()
        return updated
    }
}
