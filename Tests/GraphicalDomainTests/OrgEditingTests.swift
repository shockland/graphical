import XCTest
@testable import GraphicalDomain

final class OrgEditingTests: XCTestCase {
    private func baseOrg() -> OrgGraph {
        OrgGraph(
            nodes: [
                OrgNode(id: "a", role: "A", runner: "echo_fixture", done: .allOf([.artifact("a.md")])),
                OrgNode(id: "b", role: "B", runner: "echo_fixture", done: .allOf([.artifact("b.md")]))
            ],
            edges: [],
            entry: "a"
        )
    }

    func testInsertNodeAssignsUniqueIdAndPosition() {
        let result = OrgEditing.insertNode(into: baseOrg(), defaultRunner: "echo_fixture")
        XCTAssertEqual(result.nodeId, "node_3")
        XCTAssertTrue(result.org.nodes.contains(where: { $0.id == "node_3" }))
        XCTAssertEqual(result.position.x, 120 + 3 * 36)
    }

    func testRemoveNodeCascadesEdgesAndResetsEntry() {
        var org = baseOrg()
        org.edges = [OrgEdge(from: "a", to: "b", type: .fixed)]
        let result = OrgEditing.removeNode(id: "a", from: org)
        XCTAssertFalse(result.org.nodes.contains(where: { $0.id == "a" }))
        XCTAssertTrue(result.org.edges.isEmpty)
        XCTAssertEqual(result.org.entry, "b")
        XCTAssertEqual(result.selectedNodeId, "b")
    }

    func testConnectRouterWithExplicitTo() {
        let result = OrgEditing.connectRouter(from: "a", to: "b", in: baseOrg())
        XCTAssertEqual(result.org.edges.count, 1)
        XCTAssertEqual(result.org.edges[0].type, .router)
        XCTAssertEqual(result.org.edges[0].targets, ["b"])
        XCTAssertTrue(result.org.edges[0].requiresApproval)
    }

    func testConnectFixed() {
        let result = OrgEditing.connectFixed(from: "a", to: "b", in: baseOrg())
        XCTAssertEqual(result.org.edges[0].type, .fixed)
        XCTAssertEqual(result.org.edges[0].to, "b")
    }
}
