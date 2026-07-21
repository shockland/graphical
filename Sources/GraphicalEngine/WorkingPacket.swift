import Foundation
import GraphicalDomain

public enum WorkingPacketBuilder {
    public static func build(
        project: GraphicalProject,
        run: RunRecord,
        node: OrgNode,
        iteration: Int,
        inbound: HandoffContract?,
        missingChecks: [String],
        nodeArtifacts: URL,
        modelHint: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("# Graphical Working Packet")
        lines.append("")
        lines.append("## Run")
        lines.append("- run_id: \(run.id)")
        lines.append("- node_id: \(node.id)")
        lines.append("- role: \(node.role)")
        lines.append("- iteration: \(iteration) of \(node.maxIterations)")
        let model = modelHint ?? node.model
        if let model {
            lines.append("- model_hint: \(model)")
        }
        lines.append("- node_artifacts: \(nodeArtifacts.path)")
        lines.append("")
        lines.append("## Goal")
        lines.append(run.goal)
        lines.append("")
        lines.append("## Role Instructions")
        lines.append(node.instructions)
        lines.append("")
        if let inbound {
            lines.append("## Inbound Handoff")
            lines.append("- summary: \(inbound.summary)")
            if !inbound.artifacts.isEmpty {
                lines.append("- artifacts:")
                for artifact in inbound.artifacts {
                    lines.append("  - \(artifact)")
                }
            }
            if let notes = inbound.notes, !notes.isEmpty {
                lines.append("- notes: \(notes)")
            }
            lines.append("")
        }
        if !missingChecks.isEmpty {
            lines.append("## Still Missing")
            for check in missingChecks {
                lines.append("- \(check)")
            }
            lines.append("")
        }
        lines.append("## Required Outputs")
        lines.append("Write artifacts into: \(nodeArtifacts.path)")
        for check in node.done.checks {
            switch check {
            case .artifact(let path):
                lines.append("- Create artifact file: \(path)")
            case .shell(let command):
                lines.append("- Satisfy shell check (cwd=node artifacts): \(command)")
            case .routerNext:
                lines.append("- Write next.json: {\"node_id\":\"...\",\"reason\":\"...\"}")
            }
        }
        lines.append("")
        lines.append("Also write summary.txt with a short handoff summary.")
        return lines.joined(separator: "\n")
    }
}
