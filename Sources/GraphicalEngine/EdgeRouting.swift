import Foundation
import GraphicalDomain

/// Picks the outgoing Work-graph edge for a given `on:` filter (success/always or reject).
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
    }

    /// Filters `outgoing` by `on`, then prefers a router edge (allowlist) over a fixed `to`.
    static func select(
        outgoing: [OrgEdge],
        on conditions: Set<EdgeCondition>,
        nodeId: String,
        routerNext: RouterNext?,
        loadRouterNext: () -> RouterNext?
    ) throws -> Selection {
        let edges = outgoing.filter { conditions.contains($0.on) }
        if let routerEdge = edges.first(where: { $0.type == .router }) {
            guard let next = routerNext ?? loadRouterNext() else {
                throw Error.missingRouterNext
            }
            guard routerEdge.targets.contains(next.nodeId) else {
                throw Error.routerTargetNotAllowed(next.nodeId)
            }
            return Selection(edge: routerEdge, destination: next.nodeId, chosenRouterNext: next)
        }
        if let fixed = edges.first(where: { $0.type == .fixed }), let to = fixed.to {
            return Selection(edge: fixed, destination: to, chosenRouterNext: nil)
        }
        throw Error.noOutgoingEdge(nodeId)
    }
}
