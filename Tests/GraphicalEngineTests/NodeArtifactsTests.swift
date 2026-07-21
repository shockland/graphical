import XCTest
@testable import GraphicalDomain
@testable import GraphicalEngine

final class NodeArtifactsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("node-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadRouterNextAndReject() throws {
        try #"{"node_id":"implementer","reason":"go"}"#
            .write(to: tempDir.appendingPathComponent(NodeArtifacts.nextJSON), atomically: true, encoding: .utf8)
        try #"{"reject":true,"reason":"rework"}"#
            .write(to: tempDir.appendingPathComponent(NodeArtifacts.rejectJSON), atomically: true, encoding: .utf8)

        let next = NodeArtifacts.loadRouterNext(from: tempDir)
        XCTAssertEqual(next?.nodeId, "implementer")
        let reject = NodeArtifacts.loadReject(from: tempDir)
        XCTAssertEqual(reject?.reject, true)
        XCTAssertEqual(reject?.reason, "rework")
    }

    func testBuildContractUsesSummaryAndSkipsPacketFiles() throws {
        try "Hello summary".write(
            to: tempDir.appendingPathComponent(NodeArtifacts.summaryTXT),
            atomically: true,
            encoding: .utf8
        )
        try "body".write(to: tempDir.appendingPathComponent("out.md"), atomically: true, encoding: .utf8)
        try "pkt".write(to: tempDir.appendingPathComponent("packet-1.md"), atomically: true, encoding: .utf8)

        let contract = NodeArtifacts.buildContract(
            nodeArtifacts: tempDir,
            checks: [],
            routerNext: nil,
            summaryFallback: "fallback"
        )
        XCTAssertEqual(contract.summary, "Hello summary")
        XCTAssertTrue(contract.artifacts.contains(where: { $0.hasSuffix("out.md") }))
        XCTAssertFalse(contract.artifacts.contains(where: { $0.contains("packet-") }))
    }

    func testRequiredOutputLinesMentionRejectWhenEdgePresent() {
        let node = OrgNode(
            id: "reviewer",
            role: "Reviewer",
            runner: "echo_fixture",
            done: .allOf([.artifact("review.md")])
        )
        let org = OrgGraph(
            nodes: [node],
            edges: [OrgEdge(from: "reviewer", to: "implementer", type: .fixed, on: .reject)]
        )
        let lines = NodeArtifacts.requiredOutputLines(
            for: node,
            nodeArtifactsPath: "/tmp/out",
            org: org
        )
        XCTAssertTrue(lines.joined(separator: "\n").contains(NodeArtifacts.rejectJSON))
        XCTAssertTrue(lines.joined(separator: "\n").contains(NodeArtifacts.summaryTXT))
    }
}
