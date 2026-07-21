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
}
