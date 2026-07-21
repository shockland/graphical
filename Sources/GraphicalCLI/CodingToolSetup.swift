import Foundation
import GraphicalDomain

public enum CodingToolSetupError: Error, Equatable, Sendable {
    case unknownPreset(String)
}

/// Applies a coding-tool catalog preset to a project: upsert the stable runner key and
/// rebind every Org node to that runner (clearing per-node model overrides).
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
        for index in updated.org.nodes.indices {
            updated.org.nodes[index].runner = preset.runnerName
            updated.org.nodes[index].model = nil
        }
        return updated
    }
}
