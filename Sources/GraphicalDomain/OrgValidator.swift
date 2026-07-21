import Foundation

public enum OrgValidationIssue: Equatable, Sendable, Identifiable {
    case emptyOrg
    case missingEntry(String)
    case danglingEdge(edgeId: String, nodeId: String)
    case routerWithoutTargets(edgeId: String)
    case routerTargetUnknown(edgeId: String, target: String)
    case fixedEdgeMissingTo(edgeId: String)
    case duplicateNodeId(String)
    case unknownRunner(nodeId: String, runner: String)
    case maxIterationsInvalid(nodeId: String)
    case routerFanOutTooLarge(edgeId: String, count: Int, max: Int)
    case unsafeNodeId(String)
    case emptyDoneChecks(nodeId: String)

    public var id: String { message }

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
        }
    }
}

public enum OrgValidator {
    public static let maxRouterTargets = 8

    public static func validate(org: OrgGraph, runners: RunnersConfig) -> [OrgValidationIssue] {
        var issues: [OrgValidationIssue] = []

        if org.nodes.isEmpty {
            issues.append(.emptyOrg)
            return issues
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
            }
        }

        return issues
    }
}
