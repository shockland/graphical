import Foundation

public enum OrgValidationIssue: Equatable, Sendable, Identifiable {
    case emptyOrg
    case missingEntry(String)
    case danglingEdge(edgeId: String, nodeId: String)
    case routerWithoutTargets(edgeId: String)
    case routerTargetUnknown(edgeId: String, target: String)
    case fixedEdgeMissingTo(edgeId: String)
    case fanOutWithoutTargets(edgeId: String)
    case fanOutTargetUnknown(edgeId: String, target: String)
    case fanOutTooLarge(edgeId: String, count: Int, max: Int)
    case joinEdgeMissingTo(edgeId: String)
    case meshWidthInvalid(Int)
    case duplicateNodeId(String)
    case unknownRunner(nodeId: String, runner: String)
    case maxIterationsInvalid(nodeId: String)
    case routerFanOutTooLarge(edgeId: String, count: Int, max: Int)
    case unsafeNodeId(String)
    case emptyDoneChecks(nodeId: String)
    /// Hard-fail: mesh spine edge stripped `.artifacts` and/or `.summary` from `pass`.
    case meshSpinePassIncomplete(edgeId: String, missing: [HandoffField])
    /// Soft mesh-shape hints (do not block runs).
    case meshNoPlanners
    case meshBrokenLanePairing(plannerId: String, detail: String)
    case meshMissingAuditorJoin
    case meshMultiplePostAuditorImplementers([String])

    public var id: String { message }

    /// Warnings are advisory; errors block readiness and `RunEngine.start`.
    public var isWarning: Bool {
        switch self {
        case .meshNoPlanners,
             .meshBrokenLanePairing,
             .meshMissingAuditorJoin,
             .meshMultiplePostAuditorImplementers:
            return true
        default:
            return false
        }
    }

    /// Node to select when the user clicks this issue in the validation banner.
    public var focusNodeId: String? {
        switch self {
        case .missingEntry(let id):
            return id
        case .danglingEdge(_, let nodeId):
            return nodeId
        case .duplicateNodeId(let id):
            return id
        case .unknownRunner(let nodeId, _):
            return nodeId
        case .maxIterationsInvalid(let nodeId):
            return nodeId
        case .unsafeNodeId(let id):
            return id
        case .emptyDoneChecks(let nodeId):
            return nodeId
        case .meshBrokenLanePairing(let plannerId, _):
            return plannerId
        case .meshMultiplePostAuditorImplementers(let ids):
            return ids.first
        case .meshMissingAuditorJoin:
            return "auditor"
        default:
            return nil
        }
    }

    /// Edge to select when the user clicks this issue in the validation banner.
    public var focusEdgeId: String? {
        switch self {
        case .danglingEdge(let edgeId, _):
            return edgeId
        case .routerWithoutTargets(let edgeId):
            return edgeId
        case .routerTargetUnknown(let edgeId, _):
            return edgeId
        case .fixedEdgeMissingTo(let edgeId):
            return edgeId
        case .routerFanOutTooLarge(let edgeId, _, _):
            return edgeId
        case .fanOutWithoutTargets(let edgeId):
            return edgeId
        case .fanOutTargetUnknown(let edgeId, _):
            return edgeId
        case .fanOutTooLarge(let edgeId, _, _):
            return edgeId
        case .joinEdgeMissingTo(let edgeId):
            return edgeId
        case .meshSpinePassIncomplete(let edgeId, _):
            return edgeId
        default:
            return nil
        }
    }

    public var message: String {
        switch self {
        case .emptyOrg:
            return "Org graph has no nodes"
        case .missingEntry(let id):
            return "Entry node '\(id)' does not exist"
        case .danglingEdge(let edgeId, let nodeId):
            return "Edge '\(edgeId)' references unknown node '\(nodeId)'"
        case .routerWithoutTargets(let edgeId):
            return "Router edge '\(edgeId)' has no targets allowlist"
        case .routerTargetUnknown(let edgeId, let target):
            return "Router edge '\(edgeId)' allowlists unknown target '\(target)'"
        case .fixedEdgeMissingTo(let edgeId):
            return "Fixed edge '\(edgeId)' is missing 'to'"
        case .fanOutWithoutTargets(let edgeId):
            return "Fan-out edge '\(edgeId)' has no targets"
        case .fanOutTargetUnknown(let edgeId, let target):
            return "Fan-out edge '\(edgeId)' targets unknown node '\(target)'"
        case .fanOutTooLarge(let edgeId, let count, let max):
            return "Fan-out edge '\(edgeId)' has \(count) targets (max \(max))"
        case .joinEdgeMissingTo(let edgeId):
            return "Join edge '\(edgeId)' is missing 'to'"
        case .meshWidthInvalid(let width):
            return "meshWidth \(width) is out of range (2…\(OrgValidator.maxMeshWidth))"
        case .duplicateNodeId(let id):
            return "Duplicate node id '\(id)'"
        case .unknownRunner(let nodeId, let runner):
            return "Node '\(nodeId)' references unknown runner '\(runner)'"
        case .maxIterationsInvalid(let nodeId):
            return "Node '\(nodeId)' max_iterations must be >= 1"
        case .routerFanOutTooLarge(let edgeId, let count, let max):
            return "Router edge '\(edgeId)' has \(count) targets (max \(max))"
        case .unsafeNodeId(let id):
            return "Node id '\(id)' contains unsafe characters (allowed: letters, digits, '.', '_', '-')"
        case .emptyDoneChecks(let nodeId):
            return "Node '\(nodeId)' has no done checks (empty allOf/anyOf groups fail closed)"
        case .meshSpinePassIncomplete(let edgeId, let missing):
            let fields = missing.map(\.rawValue).joined(separator: ", ")
            return "Mesh spine edge '\(edgeId)' must pass \(fields) so handoff artifacts travel"
        case .meshNoPlanners:
            return "Mesh shape: no Planner-role nodes found"
        case .meshBrokenLanePairing(let plannerId, let detail):
            return "Mesh shape: lane pairing broken for '\(plannerId)' (\(detail))"
        case .meshMissingAuditorJoin:
            return "Mesh shape: auditor has no inbound join edges from interpreters"
        case .meshMultiplePostAuditorImplementers(let ids):
            return "Mesh shape: multiple Implementer-role nodes reachable after auditor (\(ids.joined(separator: ", ")))"
        }
    }
}

public enum OrgValidator {
    public static let maxRouterTargets = 8
    public static let maxMeshWidth = 8
    public static let minMeshWidth = 2

    public static func validate(
        org: OrgGraph,
        runners: RunnersConfig,
        meshWidth: Int? = nil
    ) -> [OrgValidationIssue] {
        var issues: [OrgValidationIssue] = []

        if org.nodes.isEmpty {
            issues.append(.emptyOrg)
            return issues
        }

        if let meshWidth, (meshWidth < minMeshWidth || meshWidth > maxMeshWidth) {
            issues.append(.meshWidthInvalid(meshWidth))
        }

        var seen = Set<String>()
        for node in org.nodes {
            if !seen.insert(node.id).inserted {
                issues.append(.duplicateNodeId(node.id))
            }
            if !PathSafety.isSafeNodeId(node.id) {
                issues.append(.unsafeNodeId(node.id))
            }
            if node.maxIterations < 1 {
                issues.append(.maxIterationsInvalid(nodeId: node.id))
            }
            if runners.runners[node.runner] == nil {
                issues.append(.unknownRunner(nodeId: node.id, runner: node.runner))
            }
            if node.done.checks.isEmpty {
                issues.append(.emptyDoneChecks(nodeId: node.id))
            }
        }

        let nodeIds = Set(org.nodes.map(\.id))

        if let entry = org.entry, !nodeIds.contains(entry) {
            issues.append(.missingEntry(entry))
        }

        for edge in org.edges {
            if !nodeIds.contains(edge.from) {
                issues.append(.danglingEdge(edgeId: edge.id, nodeId: edge.from))
            }
            switch edge.type {
            case .fixed:
                guard let to = edge.to else {
                    issues.append(.fixedEdgeMissingTo(edgeId: edge.id))
                    continue
                }
                if !nodeIds.contains(to) {
                    issues.append(.danglingEdge(edgeId: edge.id, nodeId: to))
                }
            case .join:
                guard let to = edge.to else {
                    issues.append(.joinEdgeMissingTo(edgeId: edge.id))
                    continue
                }
                if !nodeIds.contains(to) {
                    issues.append(.danglingEdge(edgeId: edge.id, nodeId: to))
                }
            case .router:
                if edge.targets.isEmpty {
                    issues.append(.routerWithoutTargets(edgeId: edge.id))
                }
                if edge.targets.count > maxRouterTargets {
                    issues.append(
                        .routerFanOutTooLarge(
                            edgeId: edge.id,
                            count: edge.targets.count,
                            max: maxRouterTargets
                        )
                    )
                }
                for target in edge.targets {
                    if !nodeIds.contains(target) {
                        issues.append(.routerTargetUnknown(edgeId: edge.id, target: target))
                    }
                }
            case .fanOut:
                if edge.targets.isEmpty {
                    issues.append(.fanOutWithoutTargets(edgeId: edge.id))
                }
                if edge.targets.count > maxMeshWidth {
                    issues.append(
                        .fanOutTooLarge(
                            edgeId: edge.id,
                            count: edge.targets.count,
                            max: maxMeshWidth
                        )
                    )
                }
                for target in edge.targets {
                    if !nodeIds.contains(target) {
                        issues.append(.fanOutTargetUnknown(edgeId: edge.id, target: target))
                    }
                }
            }
        }

        issues.append(contentsOf: meshSpinePassIssues(org: org))
        issues.append(contentsOf: meshShapeWarnings(org: org))
        return issues
    }

    /// Hard-fail when planner→interpreter, interpreter→auditor, or auditor→implementer
    /// edges strip `.artifacts` / `.summary` from `pass`. Non-mesh orgs are skipped.
    public static func meshSpinePassIssues(org: OrgGraph) -> [OrgValidationIssue] {
        guard looksLikeMesh(org) else { return [] }
        var issues: [OrgValidationIssue] = []
        for edge in org.edges {
            guard isMeshSpineEdge(edge, in: org) else { continue }
            var missing: [HandoffField] = []
            if !edge.pass.contains(.artifacts) { missing.append(.artifacts) }
            if !edge.pass.contains(.summary) { missing.append(.summary) }
            if !missing.isEmpty {
                issues.append(.meshSpinePassIncomplete(edgeId: edge.id, missing: missing))
            }
        }
        return issues
    }

    /// Soft checks for agentic-mesh shape. Skipped when the org does not look like a mesh,
    /// so non-mesh workflows (e.g. planner→implementer→reviewer) stay clean.
    public static func meshShapeWarnings(org: OrgGraph) -> [OrgValidationIssue] {
        guard looksLikeMesh(org) else { return [] }

        var warnings: [OrgValidationIssue] = []
        let planners = org.nodes.filter { $0.role == "Planner" || $0.id.hasPrefix("planner-") }
        if planners.isEmpty {
            warnings.append(.meshNoPlanners)
        }

        let auditorId = org.nodes.first(where: { $0.role == "Auditor" || $0.id == "auditor" })?.id
        let numberedPlanners = planners.compactMap { node -> (id: String, lane: Int)? in
            guard let lane = laneIndex(node.id) else { return nil }
            return (node.id, lane)
        }

        for pair in numberedPlanners {
            let interpreterId = "interpreter-\(pair.lane)"
            guard let interpreter = org.node(id: interpreterId) else {
                warnings.append(
                    .meshBrokenLanePairing(
                        plannerId: pair.id,
                        detail: "missing \(interpreterId)"
                    )
                )
                continue
            }
            if interpreter.role != "Interpreter" {
                warnings.append(
                    .meshBrokenLanePairing(
                        plannerId: pair.id,
                        detail: "\(interpreterId) role is '\(interpreter.role)', expected Interpreter"
                    )
                )
            }
            let hasLaneEdge = org.edges.contains {
                $0.type == .fixed && $0.from == pair.id && $0.to == interpreterId
                    && ($0.on == .success || $0.on == .always)
            }
            if !hasLaneEdge {
                warnings.append(
                    .meshBrokenLanePairing(
                        plannerId: pair.id,
                        detail: "no success fixed edge to \(interpreterId)"
                    )
                )
            }
            if let auditorId {
                let hasJoin = org.edges.contains {
                    $0.type == .join && $0.from == interpreterId && $0.to == auditorId
                }
                if !hasJoin {
                    warnings.append(
                        .meshBrokenLanePairing(
                            plannerId: pair.id,
                            detail: "\(interpreterId) does not join into \(auditorId)"
                        )
                    )
                }
            }
        }

        if let auditorId {
            let joinPreds = org.joinPredecessors(of: auditorId)
            if joinPreds.isEmpty {
                warnings.append(.meshMissingAuditorJoin)
            }
            let implementers = reachableImplementers(after: auditorId, in: org)
            if implementers.count > 1 {
                warnings.append(.meshMultiplePostAuditorImplementers(implementers))
            }
        }

        return warnings
    }

    private static func looksLikeMesh(_ org: OrgGraph) -> Bool {
        if org.edges.contains(where: { $0.type == .fanOut || $0.type == .join }) {
            return true
        }
        if org.nodes.contains(where: { $0.role == "Auditor" || $0.id == "auditor" }) {
            return true
        }
        if org.nodes.contains(where: { $0.id.hasPrefix("planner-") || $0.id.hasPrefix("interpreter-") }) {
            return true
        }
        return false
    }

    /// Spine edges that must carry summary + artifacts for mesh handoff fidelity.
    private static func isMeshSpineEdge(_ edge: OrgEdge, in org: OrgGraph) -> Bool {
        let from = org.node(id: edge.from)
        let toId = edge.to
        let to = toId.flatMap { org.node(id: $0) }

        // planner-N → interpreter-N (fixed)
        if edge.type == .fixed,
           let from,
           let to,
           (from.role == "Planner" || from.id.hasPrefix("planner-")),
           (to.role == "Interpreter" || to.id.hasPrefix("interpreter-")) {
            return true
        }

        // interpreter-N → auditor (join)
        if edge.type == .join,
           let from,
           let to,
           (from.role == "Interpreter" || from.id.hasPrefix("interpreter-")),
           (to.role == "Auditor" || to.id == "auditor") {
            return true
        }

        // auditor → implementer (fixed success path)
        if edge.type == .fixed,
           let from,
           let to,
           (from.role == "Auditor" || from.id == "auditor"),
           to.role == "Implementer" {
            return true
        }

        return false
    }

    private static func laneIndex(_ nodeId: String) -> Int? {
        guard let dash = nodeId.lastIndex(of: "-") else { return nil }
        return Int(nodeId[nodeId.index(after: dash)...])
    }

    /// Implementer-role nodes reachable on the success path starting from `auditorId`
    /// (excluding the auditor itself).
    private static func reachableImplementers(after auditorId: String, in org: OrgGraph) -> [String] {
        var visited = Set<String>()
        var queue = [auditorId]
        var found: [String] = []
        while let current = queue.first {
            queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            for next in org.successNextNodeIds(from: current) {
                if let node = org.node(id: next), node.role == "Implementer", next != auditorId {
                    if !found.contains(next) {
                        found.append(next)
                    }
                }
                queue.append(next)
            }
        }
        return found
    }
}
