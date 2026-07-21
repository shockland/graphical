import Foundation
import GraphicalDomain

/// `reject.json` convention read from a node's own artifacts after its done-checks
/// pass; see plans/009-decision.md. Missing `reject` key (or any other decode
/// mismatch) is treated as "no reject" by the caller, not as `reject: false`.
struct RejectSignal: Decodable, Equatable, Sendable {
    var reject: Bool
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case reject, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reject = try container.decodeIfPresent(Bool.self, forKey: .reject) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Owns node-artifact filename conventions and Handoff contract assembly from disk.
public enum NodeArtifacts {
    public static let nextJSON = "next.json"
    public static let rejectJSON = "reject.json"
    public static let summaryTXT = "summary.txt"
    public static let packetPrefix = "packet-"

    public static func loadRouterNext(from directory: URL) -> RouterNext? {
        let url = directory.appendingPathComponent(nextJSON)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RouterNext.self, from: data)
    }

    static func loadReject(from directory: URL) -> RejectSignal? {
        let url = directory.appendingPathComponent(rejectJSON)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RejectSignal.self, from: data)
    }

    public static func buildContract(
        nodeArtifacts directory: URL,
        checks: [CheckResult],
        routerNext: RouterNext?,
        summaryFallback: String,
        fileManager: FileManager = .default
    ) -> HandoffContract {
        let summaryURL = directory.appendingPathComponent(summaryTXT)
        let summary: String
        if let text = try? String(contentsOf: summaryURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            summary = summaryFallback
            try? summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        let artifactFiles = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let artifacts = artifactFiles
            .filter { !$0.hasPrefix(packetPrefix) && $0 != summaryTXT }
            .map { directory.appendingPathComponent($0).path }

        return HandoffContract(
            summary: summary,
            artifacts: artifacts,
            checks: checks,
            next: routerNext,
            notes: nil
        )
    }

    /// Lines under Working Packet "Required Outputs" for done-checks + summary/reject.
    public static func requiredOutputLines(
        for node: OrgNode,
        nodeArtifactsPath: String,
        org: OrgGraph
    ) -> [String] {
        var lines: [String] = []
        lines.append("Write artifacts into: \(nodeArtifactsPath)")
        for check in node.done.checks {
            switch check {
            case .artifact(let path):
                lines.append("- Create artifact file: \(path)")
            case .shell(let command):
                lines.append("- Satisfy shell check (cwd=node artifacts): \(command)")
            case .routerNext:
                lines.append(
                    "- Write \(nextJSON): {\"node_id\":\"...\",\"reason\":\"...\"}"
                )
            }
        }
        lines.append("")
        lines.append("Also write \(summaryTXT) with a short handoff summary.")
        if org.outgoingEdges(from: node.id).contains(where: { $0.on == .reject }) {
            lines.append(
                "To send this back instead of proceeding, write \(rejectJSON): "
                    + "{\"reject\":true,\"reason\":\"...\"} (an 'on: reject' edge exists from this node)."
            )
        }
        return lines
    }
}
