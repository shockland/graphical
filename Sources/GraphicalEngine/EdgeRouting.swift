import Foundation
import GraphicalDomain

/// Picks the outgoing Work-graph edge for a given `on:` filter (success/always or reject).
/// Router = XOR (one allowlisted target). Fan-out is handled by `RunEngine`, not here.
enum EdgeRouting {
    struct Selection: Equatable {
        var edge: OrgEdge
        var destination: String
        var chosenRouterNext: RouterNext?
    }

    enum Error: Swift.Error, Equatable {
        case missingRouterNext
        case routerTargetNotAllowed(String)
        case noOutgoingEdge(String)
        case fanOutNotSelectable(String)
    }

    /// Filters `outgoing` by `on`, then prefers a router edge (allowlist) over fixed/join `to`.
    /// Fan-out edges must be scheduled by the engine ready-queue, not selected as a single hop.
    static func select(
        outgoing: [OrgEdge],
        on conditions: Set<EdgeCondition>,
        nodeId: String,
        routerNext: RouterNext?,
        loadRouterNext: () -> RouterNext?
    ) throws -> Selection {
        let edges = outgoing.filter { conditions.contains($0.on) }
        if edges.contains(where: { $0.type == .fanOut }) {
            throw Error.fanOutNotSelectable(nodeId)
        }
        if let routerEdge = edges.first(where: { $0.type == .router }) {
            guard let next = routerNext ?? loadRouterNext() else {
                throw Error.missingRouterNext
            }
            guard routerEdge.targets.contains(next.nodeId) else {
                throw Error.routerTargetNotAllowed(next.nodeId)
            }
            return Selection(edge: routerEdge, destination: next.nodeId, chosenRouterNext: next)
        }
        if let join = edges.first(where: { $0.type == .join }), let to = join.to {
            return Selection(edge: join, destination: to, chosenRouterNext: nil)
        }
        if let fixed = edges.first(where: { $0.type == .fixed }), let to = fixed.to {
            return Selection(edge: fixed, destination: to, chosenRouterNext: nil)
        }
        throw Error.noOutgoingEdge(nodeId)
    }

    /// Returns the fan-out edge among filtered success edges, if any.
    static func fanOutEdge(in outgoing: [OrgEdge], on conditions: Set<EdgeCondition>) -> OrgEdge? {
        outgoing.first { conditions.contains($0.on) && $0.type == .fanOut }
    }
}
