import Foundation
import GraphicalDomain

public enum CodingToolSetupError: Error, Equatable, Sendable {
    case unknownPreset(String)
}

/// Applies a coding-tool catalog preset to a project: upsert the stable runner key and
/// rebind Org nodes to that runner (clearing per-node model overrides), skipping
/// planner nodes the user has already customized.
public enum CodingToolSetup {
    public static func apply(
        presetID: String,
        to project: GraphicalProject
    ) throws -> GraphicalProject {
        guard let preset = AgentPresetCatalog.preset(id: presetID) else {
            throw CodingToolSetupError.unknownPreset(presetID)
        }
        var updated = project
        do {
            updated.runners = try AgentPresetCatalog.applying(
                presetID: presetID,
                to: updated.runners
            )
        } catch AgentPresetCatalogError.unknownPreset(let id) {
            throw CodingToolSetupError.unknownPreset(id)
        }
        let baselineRunner = sharedCodingToolBaseline(in: updated.org)
        for index in updated.org.nodes.indices {
            let node = updated.org.nodes[index]
            if isCustomizedPlanner(node, baselineRunner: baselineRunner) {
                continue
            }
            updated.org.nodes[index].runner = preset.runnerName
            updated.org.nodes[index].model = nil
        }
        return updated
    }

    /// Most common runner among non-Planner nodes (falls back to all nodes). Used as the
    /// "shared coding tool" baseline so diverged planners are not clobbered.
    public static func sharedCodingToolBaseline(in org: OrgGraph) -> String? {
        let pool = org.nodes.filter { $0.role != "Planner" }
        let source = pool.isEmpty ? org.nodes : pool
        guard !source.isEmpty else { return nil }
        let counts = Dictionary(grouping: source, by: \.runner).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key
    }

    /// Heuristic (no schema flag): a Planner is customized when it has a model override
    /// or its runner differs from the shared non-planner baseline.
    public static func isCustomizedPlanner(_ node: OrgNode, baselineRunner: String?) -> Bool {
        guard node.role == "Planner" else { return false }
        if node.model != nil { return true }
        guard let baselineRunner else { return false }
        return node.runner != baselineRunner
    }
}
