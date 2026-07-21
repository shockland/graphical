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
