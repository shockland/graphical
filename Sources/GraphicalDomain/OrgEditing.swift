import Foundation

/// Pure Org graph mutations for canvas / inspector / future CLI editors.
/// AppKit supplies IDs from gestures; defaults and cascade rules live here.
public enum OrgEditing {
    public struct InsertResult: Equatable, Sendable {
        public var org: OrgGraph
        public var nodeId: String
        public var position: NodePosition
    }

    public struct EdgeResult: Equatable, Sendable {
        public var org: OrgGraph
        public var edgeId: String
    }

    public struct RemoveNodeResult: Equatable, Sendable {
        public var org: OrgGraph
        public var removedNodeId: String
        /// New selection hint after delete (entry or nil).
        public var selectedNodeId: String?
    }

    /// Inserts a node with stable defaults; `defaultRunner` should be an existing runner key.
    public static func insertNode(
        into org: OrgGraph,
        defaultRunner: String,
        role: String = "Role",
        instructions: String = "Describe this role.",
        done: DoneCheckGroup = .allOf([.artifact("output.md")]),
        maxIterations: Int = 3
    ) -> InsertResult {
        var next = org
        let id = nextAvailableNodeId(in: next)
        next.nodes.append(
            OrgNode(
                id: id,
                role: role,
                runner: defaultRunner,
                instructions: instructions,
                done: done,
                maxIterations: maxIterations
            )
        )
        if next.entry == nil {
            next.entry = id
        }
        let offset = Double(next.nodes.count) * 36
        return InsertResult(
            org: next,
            nodeId: id,
            position: NodePosition(x: 120 + offset, y: 120 + offset)
        )
    }

    public static func replaceNode(_ node: OrgNode, in org: OrgGraph) -> OrgGraph {
        var next = org
        if let idx = next.nodes.firstIndex(where: { $0.id == node.id }) {
            next.nodes[idx] = node
        }
        return next
    }

    /// Copies `runner` + `model` from `sourceId` onto every other node with the same `role`.
    /// Returns the updated org and how many peers changed.
    public static func mirrorAgentAndModel(
        from sourceId: String,
        in org: OrgGraph
    ) -> (org: OrgGraph, updatedCount: Int) {
        guard let source = org.node(id: sourceId) else {
            return (org, 0)
        }
        var next = org
        var updatedCount = 0
        for index in next.nodes.indices {
            let node = next.nodes[index]
            guard node.id != sourceId, node.role == source.role else { continue }
            guard node.runner != source.runner || node.model != source.model else { continue }
            next.nodes[index].runner = source.runner
            next.nodes[index].model = source.model
            updatedCount += 1
        }
        return (next, updatedCount)
    }

    public static func removeNode(id: String, from org: OrgGraph) -> RemoveNodeResult {
        var next = org
        next.nodes.removeAll { $0.id == id }
        next.edges.removeAll { $0.from == id || $0.to == id || $0.targets.contains(id) }
        if next.entry == id {
            next.entry = next.nodes.first?.id
        }
        return RemoveNodeResult(
            org: next,
            removedNodeId: id,
            selectedNodeId: next.entryNodeId
        )
    }

    public static func setEntry(_ id: String, in org: OrgGraph) -> OrgGraph {
        var next = org
        next.entry = id
        return next
    }

    public static func connectFixed(
        from: String,
        to: String,
        in org: OrgGraph,
        on: EdgeCondition = .success
    ) -> EdgeResult {
        var next = org
        let edge = OrgEdge(from: from, to: to, type: .fixed, on: on)
        next.edges.append(edge)
        return EdgeResult(org: next, edgeId: edge.id)
    }

    /// Connects a router edge. When `to` is set, targets are `[to]`; otherwise up to
    /// two other nodes (falling back to `from` when the org has a single node).
    public static func connectRouter(
        from: String,
        to: String? = nil,
        in org: OrgGraph,
        requiresApproval: Bool = true,
        on: EdgeCondition = .success
    ) -> EdgeResult {
        var next = org
        let targets: [String]
        if let to {
            targets = [to]
        } else {
            let others = Array(org.nodes.filter { $0.id != from }.prefix(2).map(\.id))
            targets = others.isEmpty ? [from] : others
        }
        let edge = OrgEdge(
            from: from,
            type: .router,
            targets: targets,
            on: on,
            requiresApproval: requiresApproval
        )
        next.edges.append(edge)
        return EdgeResult(org: next, edgeId: edge.id)
    }

    /// Connects a fan-out edge that activates all `targets` after success.
    public static func connectFanOut(
        from: String,
        targets: [String],
        in org: OrgGraph,
        on: EdgeCondition = .success
    ) -> EdgeResult {
        var next = org
        let edge = OrgEdge(from: from, type: .fanOut, targets: targets, on: on)
        next.edges.append(edge)
        return EdgeResult(org: next, edgeId: edge.id)
    }

    /// Connects a join barrier edge; destination waits for all inbound join predecessors.
    public static func connectJoin(
        from: String,
        to: String,
        in org: OrgGraph,
        on: EdgeCondition = .success
    ) -> EdgeResult {
        var next = org
        let edge = OrgEdge(from: from, to: to, type: .join, on: on)
        next.edges.append(edge)
        return EdgeResult(org: next, edgeId: edge.id)
    }

    public static func replaceEdge(_ edge: OrgEdge, in org: OrgGraph) -> OrgGraph {
        var next = org
        if let idx = next.edges.firstIndex(where: { $0.id == edge.id }) {
            next.edges[idx] = edge
        }
        return next
    }

    public static func removeEdge(id: String, from org: OrgGraph) -> OrgGraph {
        var next = org
        next.edges.removeAll { $0.id == id }
        return next
    }

    public static func nextAvailableNodeId(in org: OrgGraph) -> String {
        var n = org.nodes.count + 1
        var candidate = "node_\(n)"
        let existing = Set(org.nodes.map(\.id))
        while existing.contains(candidate) {
            n += 1
            candidate = "node_\(n)"
        }
        return candidate
    }
}
