import XCTest
@testable import GraphicalDomain
@testable import GraphicalEngine

final class EdgeRoutingTests: XCTestCase {
    func testSelectsFixedSuccessEdge() throws {
        let edges = [
            OrgEdge(from: "a", to: "b", type: .fixed, on: .success)
        ]
        let selection = try EdgeRouting.select(
            outgoing: edges,
            on: [.success, .always],
            nodeId: "a",
            routerNext: nil,
            loadRouterNext: { nil }
        )
        XCTAssertEqual(selection.destination, "b")
        XCTAssertEqual(selection.edge.type, .fixed)
    }

    func testSelectsRejectFixedEdge() throws {
        let edges = [
            OrgEdge(from: "reviewer", to: "implementer", type: .fixed, on: .reject)
        ]
        let selection = try EdgeRouting.select(
            outgoing: edges,
            on: [.reject],
            nodeId: "reviewer",
            routerNext: nil,
            loadRouterNext: { nil }
        )
        XCTAssertEqual(selection.destination, "implementer")
    }

    func testRouterAllowlistEnforced() {
        let edges = [
            OrgEdge(from: "planner", type: .router, targets: ["implementer"], on: .success)
        ]
        XCTAssertThrowsError(
            try EdgeRouting.select(
                outgoing: edges,
                on: [.success, .always],
                nodeId: "planner",
                routerNext: RouterNext(nodeId: "ghost", reason: "nope"),
                loadRouterNext: { nil }
            )
        ) { error in
            XCTAssertEqual(error as? EdgeRouting.Error, .routerTargetNotAllowed("ghost"))
        }
    }

    func testSelectsJoinEdgeLikeFixed() throws {
        let edges = [
            OrgEdge(from: "interpreter-1", to: "auditor", type: .join, on: .success)
        ]
        let selection = try EdgeRouting.select(
            outgoing: edges,
            on: [.success, .always],
            nodeId: "interpreter-1",
            routerNext: nil,
            loadRouterNext: { nil }
        )
        XCTAssertEqual(selection.destination, "auditor")
        XCTAssertEqual(selection.edge.type, .join)
    }

    func testFanOutIsNotSelectableAsSingleHop() {
        let edges = [
            OrgEdge(from: "entry", type: .fanOut, targets: ["planner-1", "planner-2"], on: .success)
        ]
        XCTAssertThrowsError(
            try EdgeRouting.select(
                outgoing: edges,
                on: [.success, .always],
                nodeId: "entry",
                routerNext: nil,
                loadRouterNext: { nil }
            )
        ) { error in
            XCTAssertEqual(error as? EdgeRouting.Error, .fanOutNotSelectable("entry"))
        }
    }

    func testFanOutEdgeHelperFindsFanOut() {
        let edges = [
            OrgEdge(from: "entry", to: "other", type: .fixed, on: .fail),
            OrgEdge(from: "entry", type: .fanOut, targets: ["a", "b"], on: .success)
        ]
        let found = EdgeRouting.fanOutEdge(in: edges, on: [.success, .always])
        XCTAssertEqual(found?.type, .fanOut)
        XCTAssertEqual(found?.targets, ["a", "b"])
    }
}
