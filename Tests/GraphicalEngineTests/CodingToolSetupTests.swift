import XCTest
@testable import GraphicalDomain
@testable import GraphicalCLI

final class CodingToolSetupTests: XCTestCase {
    func testApplyRebindsAllNodesAndUpsertsRunner() throws {
        var project = GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/p"),
            config: ProjectConfig(name: "t"),
            org: OrgGraph(
                nodes: [
                    OrgNode(id: "a", role: "A", runner: "echo_fixture", model: "old", done: .allOf([.artifact("a.md")])),
                    OrgNode(id: "b", role: "B", runner: "echo_fixture", done: .allOf([.artifact("b.md")]))
                ],
                entry: "a"
            ),
            runners: RunnersConfig(runners: [
                "echo_fixture": RunnerTemplate(command: "/bin/echo", kind: .custom)
            ])
        )

        project = try CodingToolSetup.apply(presetID: "claude-code", to: project)
        XCTAssertTrue(project.runners.runners.keys.contains("claude_code"))
        XCTAssertTrue(project.org.nodes.allSatisfy { $0.runner == "claude_code" })
        XCTAssertTrue(project.org.nodes.allSatisfy { $0.model == nil })
    }

    func testApplySkipsCustomizedPlanners() throws {
        var org = SeedTemplate.agenticMesh(width: 2)
        guard let p1 = org.nodes.firstIndex(where: { $0.id == "planner-1" }) else {
            return XCTFail("missing planner-1")
        }
        org.nodes[p1].runner = "cursor_agent"
        org.nodes[p1].model = "cursor-grok-4.5-high"

        var project = GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/p"),
            config: ProjectConfig(name: "t"),
            org: org,
            runners: SeedTemplate.defaultRunners()
        )
        project = try CodingToolSetup.apply(presetID: "claude-code", to: project)

        XCTAssertEqual(project.org.node(id: "planner-1")?.runner, "cursor_agent")
        XCTAssertEqual(project.org.node(id: "planner-1")?.model, "cursor-grok-4.5-high")
        XCTAssertEqual(project.org.node(id: "planner-2")?.runner, "claude_code")
        XCTAssertNil(project.org.node(id: "planner-2")?.model)
        XCTAssertEqual(project.org.node(id: "auditor")?.runner, "claude_code")
        XCTAssertNil(project.org.node(id: "implementer")?.model)
    }

    func testApplySkipsModelOnlyCustomizedPlanner() throws {
        var org = SeedTemplate.agenticMesh(width: 2)
        guard let p1 = org.nodes.firstIndex(where: { $0.id == "planner-1" }) else {
            return XCTFail("missing planner-1")
        }
        // Same runner as peers; only model diverges.
        org.nodes[p1].model = "opus"

        var project = GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/p"),
            config: ProjectConfig(name: "t"),
            org: org,
            runners: SeedTemplate.defaultRunners()
        )
        project = try CodingToolSetup.apply(presetID: "claude-code", to: project)

        XCTAssertEqual(project.org.node(id: "planner-1")?.runner, "echo_fixture")
        XCTAssertEqual(project.org.node(id: "planner-1")?.model, "opus")
        XCTAssertEqual(project.org.node(id: "planner-2")?.runner, "claude_code")
        XCTAssertNil(project.org.node(id: "planner-2")?.model)
    }

    func testApplySkipsRunnerOnlyCustomizedPlanner() throws {
        var org = SeedTemplate.agenticMesh(width: 2)
        guard let p1 = org.nodes.firstIndex(where: { $0.id == "planner-1" }) else {
            return XCTFail("missing planner-1")
        }
        org.nodes[p1].runner = "cursor_agent"
        org.nodes[p1].model = nil

        var project = GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/p"),
            config: ProjectConfig(name: "t"),
            org: org,
            runners: SeedTemplate.defaultRunners()
        )
        // Ensure baseline among non-planners is echo_fixture so runner diverge counts.
        XCTAssertEqual(
            CodingToolSetup.sharedCodingToolBaseline(in: org),
            "echo_fixture"
        )
        project = try CodingToolSetup.apply(presetID: "claude-code", to: project)

        XCTAssertEqual(project.org.node(id: "planner-1")?.runner, "cursor_agent")
        XCTAssertNil(project.org.node(id: "planner-1")?.model)
        XCTAssertEqual(project.org.node(id: "planner-2")?.runner, "claude_code")
    }

    func testApplyStillClearsNonPlannerModels() throws {
        var org = SeedTemplate.agenticMesh(width: 2)
        guard let auditor = org.nodes.firstIndex(where: { $0.id == "auditor" }) else {
            return XCTFail("missing auditor")
        }
        guard let implementer = org.nodes.firstIndex(where: { $0.id == "implementer" }) else {
            return XCTFail("missing implementer")
        }
        org.nodes[auditor].model = "opus"
        org.nodes[implementer].model = "sonnet"

        var project = GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/p"),
            config: ProjectConfig(name: "t"),
            org: org,
            runners: SeedTemplate.defaultRunners()
        )
        project = try CodingToolSetup.apply(presetID: "claude-code", to: project)

        XCTAssertEqual(project.org.node(id: "auditor")?.runner, "claude_code")
        XCTAssertNil(project.org.node(id: "auditor")?.model)
        XCTAssertEqual(project.org.node(id: "implementer")?.runner, "claude_code")
        XCTAssertNil(project.org.node(id: "implementer")?.model)
    }

    func testUnknownPresetThrows() {
        let project = GraphicalProject(
            root: URL(fileURLWithPath: "/tmp/p"),
            config: ProjectConfig(name: "t"),
            org: OrgGraph(),
            runners: RunnersConfig()
        )
        XCTAssertThrowsError(try CodingToolSetup.apply(presetID: "nope", to: project)) { error in
            XCTAssertEqual(error as? CodingToolSetupError, .unknownPreset("nope"))
        }
    }
}
