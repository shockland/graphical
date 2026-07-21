import XCTest
@testable import GraphicalDomain
@testable import GraphicalEngine

/// Dedicated characterization tests for `WorkingPacketBuilder` (plans/012):
/// asserts the assembled prompt string carries the inbound summary, missing
/// checks, and required output paths that downstream agent runners depend on.
final class WorkingPacketBuilderTests: XCTestCase {
    private func makeNode(
        id: String = "implementer",
        done: DoneCheckGroup = .allOf([.artifact("implementation.md")])
    ) -> OrgNode {
        OrgNode(
            id: id,
            role: "Implementer",
            runner: "echo_fixture",
            instructions: "Follow the plan.",
            done: done,
            maxIterations: 5
        )
    }

    private func makeRun(goal: String = "Build the feature") -> RunRecord {
        RunRecord(projectRoot: "/tmp/project", goal: goal)
    }

    private func makeProject(org: OrgGraph = OrgGraph()) -> GraphicalProject {
        GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/project"),
            config: ProjectConfig(name: "Test"),
            org: org,
            runners: RunnersConfig()
        )
    }

    func testPacketIncludesInboundSummaryAndArtifacts() {
        let node = makeNode()
        let inbound = HandoffContract(
            summary: "Planner produced a three-step plan",
            artifacts: ["plan.md"],
            notes: "Watch out for edge cases"
        )
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: inbound,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/implementer")
        )

        XCTAssertTrue(packet.contains("## Inbound Handoff"))
        XCTAssertTrue(packet.contains("Planner produced a three-step plan"))
        XCTAssertTrue(packet.contains("plan.md"))
        XCTAssertTrue(packet.contains("Watch out for edge cases"))
    }

    func testPacketOmitsInboundSectionWhenNil() {
        let node = makeNode()
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/implementer")
        )
        XCTAssertFalse(packet.contains("## Inbound Handoff"))
    }

    func testPacketListsMissingChecksWhenPresent() {
        let node = makeNode()
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 2,
            inbound: nil,
            missingChecks: ["artifact:implementation.md", "shell:test -f implementation.md"],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/implementer")
        )
        XCTAssertTrue(packet.contains("## Still Missing"))
        XCTAssertTrue(packet.contains("artifact:implementation.md"))
        XCTAssertTrue(packet.contains("shell:test -f implementation.md"))
    }

    func testPacketOmitsMissingChecksSectionWhenEmpty() {
        let node = makeNode()
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/implementer")
        )
        XCTAssertFalse(packet.contains("## Still Missing"))
    }

    func testPacketMentionsRequiredArtifactOutputPaths() {
        let node = makeNode(done: .allOf([.artifact("output.md"), .shell("test -f output.md")]))
        let nodeArtifacts = URL(fileURLWithPath: "/tmp/artifacts/implementer")
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: nodeArtifacts
        )
        XCTAssertTrue(packet.contains("## Required Outputs"))
        XCTAssertTrue(packet.contains(nodeArtifacts.path))
        XCTAssertTrue(packet.contains("Create artifact file: output.md"))
        XCTAssertTrue(packet.contains("Satisfy shell check (cwd=node artifacts): test -f output.md"))
    }

    func testPacketMentionsRouterNextOutputWhenGroupIncludesIt() {
        let node = makeNode(done: .allOf([.artifact("plan.md"), .routerNext]))
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/planner")
        )
        XCTAssertTrue(packet.contains("Write next.json"))
    }

    func testPacketIncludesGoalRoleAndIterationHeader() {
        let node = makeNode(id: "planner")
        let run = makeRun(goal: "Ship the widget")
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: run,
            node: node,
            iteration: 3,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/planner")
        )
        XCTAssertTrue(packet.contains("## Goal"))
        XCTAssertTrue(packet.contains("Ship the widget"))
        XCTAssertTrue(packet.contains("node_id: planner"))
        XCTAssertTrue(packet.contains("iteration: 3 of \(node.maxIterations)"))
    }

    func testPacketMentionsRejectJsonOnlyWhenRejectEdgeExists() {
        let nodeA = makeNode(id: "a", done: .allOf([.artifact("output.md")]))
        let nodeB = makeNode(id: "b", done: .allOf([.artifact("output.md")]))
        let edgeAB = OrgEdge(from: "a", to: "b", type: .fixed, on: .success)
        let edgeBA = OrgEdge(from: "b", to: "a", type: .fixed, on: .reject)
        let org = OrgGraph(nodes: [nodeA, nodeB], edges: [edgeAB, edgeBA], entry: "a")

        let packetB = WorkingPacketBuilder.build(
            project: makeProject(org: org),
            run: makeRun(),
            node: nodeB,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/b")
        )
        XCTAssertTrue(packetB.contains("reject.json"))

        let packetA = WorkingPacketBuilder.build(
            project: makeProject(org: org),
            run: makeRun(),
            node: nodeA,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/a")
        )
        XCTAssertFalse(packetA.contains("reject.json"))
    }

    func testPacketUsesModelHintOverNodeModel() {
        var node = makeNode()
        node.model = "sonnet"
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/implementer"),
            modelHint: "opus"
        )
        XCTAssertTrue(packet.contains("model_hint: opus"))
        XCTAssertFalse(packet.contains("model_hint: sonnet"))
    }

    func testPacketListsMultiInboundHandoffs() {
        let node = makeNode(id: "auditor")
        let inbounds: [(fromNodeId: String, contract: HandoffContract)] = [
            ("interpreter-1", HandoffContract(
                summary: "Lane 1 ready",
                artifacts: ["/tmp/run/interpreter-1/interpretation.md"]
            )),
            ("interpreter-2", HandoffContract(
                summary: "Lane 2 ready",
                artifacts: ["/tmp/run/interpreter-2/interpretation.md"]
            ))
        ]
        let packet = WorkingPacketBuilder.build(
            project: makeProject(),
            run: makeRun(),
            node: node,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts/auditor"),
            inbounds: inbounds
        )
        XCTAssertTrue(packet.contains("## Inbound Handoffs"))
        XCTAssertTrue(packet.contains("### From interpreter-1"))
        XCTAssertTrue(packet.contains("### From interpreter-2"))
        XCTAssertTrue(packet.contains("Lane 1 ready"))
        XCTAssertTrue(packet.contains("/tmp/run/interpreter-2/interpretation.md"))
        XCTAssertFalse(packet.contains("## Inbound Handoff\n"))
    }
}
