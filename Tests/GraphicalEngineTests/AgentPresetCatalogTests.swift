import XCTest
@testable import GraphicalCLI
@testable import GraphicalDomain

final class AgentPresetCatalogTests: XCTestCase {
    func testCursorPresetEnablesStreamJSONPartialOutput() {
        let script = AgentPresetCatalog.cursorAgent.makeRunnerTemplate().args.last ?? ""
        XCTAssertTrue(script.contains("--output-format stream-json"), script)
        XCTAssertTrue(script.contains("--stream-partial-output"), script)
        let seed = SeedTemplate.defaultRunners().runners["cursor_agent"]?.args.last ?? ""
        XCTAssertTrue(seed.contains("--output-format stream-json"), seed)
        XCTAssertTrue(seed.contains("--stream-partial-output"), seed)
    }

    func testCatalogHasStablePresetsAndFactories() {
        XCTAssertEqual(AgentPresetCatalog.all.map(\.id), [
            "demo",
            "claude-code",
            "cursor-agent",
            "codex"
        ])
        XCTAssertEqual(AgentPresetCatalog.demo.runnerName, "echo_fixture")
        XCTAssertNil(AgentPresetCatalog.demo.probe)

        for preset in AgentPresetCatalog.all {
            let template = preset.makeRunnerTemplate()
            XCTAssertEqual(template.kind, preset.kind)
            XCTAssertEqual(template.defaultModel, preset.defaultModel)
            XCTAssertFalse(template.command.isEmpty)
        }
    }

    func testShellPresetFactoriesUseBareSubstitutionsAndRenderSafely() throws {
        let context = RunnerContext(
            projectRoot: URL(fileURLWithPath: "/tmp/project $(touch bad)"),
            promptFile: URL(fileURLWithPath: "/tmp/prompt's.md"),
            nodeArtifacts: URL(fileURLWithPath: "/tmp/artifacts"),
            runArtifacts: URL(fileURLWithPath: "/tmp/run"),
            runId: "run",
            nodeId: "node",
            model: "model"
        )

        for preset in [
            AgentPresetCatalog.demo,
            AgentPresetCatalog.cursorAgent,
            AgentPresetCatalog.codex
        ] {
            let template = preset.makeRunnerTemplate()
            let script = try XCTUnwrap(template.args.last)
            XCTAssertFalse(script.contains("\"{{project_root}}\""))
            XCTAssertFalse(script.contains("\"{{prompt_file}}\""))

            let rendered = TemplateRenderer.render(runner: template, context: context)
            let renderedScript = try XCTUnwrap(rendered.args.last)
            XCTAssertTrue(renderedScript.contains(
                ShellEscape.singleQuoted(context.promptFile.path)
            ) || preset.id == AgentPresetCatalog.demo.id)
        }
    }

    func testApplyingPresetIsIdempotentAndProducesValidAssignedSeed() throws {
        var runners = RunnersConfig()
        runners = try AgentPresetCatalog.applying(presetID: "codex", to: runners)
        let once = runners
        runners = try AgentPresetCatalog.applying(presetID: "codex", to: runners)
        XCTAssertEqual(runners, once)

        let preset = try XCTUnwrap(AgentPresetCatalog.preset(id: "codex"))
        let org = SeedTemplate.plannerImplementerReviewer(
            runnerName: preset.runnerName,
            agentKind: preset.kind
        )
        XCTAssertTrue(OrgValidator.validate(org: org, runners: runners).isEmpty)
        XCTAssertTrue(org.nodes.allSatisfy { $0.model == nil })
    }

    func testUnknownPresetCannotBeApplied() {
        XCTAssertThrowsError(
            try AgentPresetCatalog.applying(presetID: "custom-command", to: RunnersConfig())
        ) { error in
            XCTAssertEqual(error as? AgentPresetCatalogError, .unknownPreset("custom-command"))
        }
    }

    func testInstallHintsPresentForRealCLIsOnly() throws {
        XCTAssertNil(AgentPresetCatalog.demo.installHint)
        for preset in [AgentPresetCatalog.claudeCode, AgentPresetCatalog.cursorAgent, AgentPresetCatalog.codex] {
            let hint = try XCTUnwrap(preset.installHint)
            XCTAssertFalse(hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testInferredPresetIDWhenAllNodesShareCatalogRunner() throws {
        let runners = try AgentPresetCatalog.applying(presetID: "claude-code", to: RunnersConfig())
        let org = SeedTemplate.plannerImplementerReviewer(
            runnerName: "claude_code",
            agentKind: .claudeCode
        )
        XCTAssertEqual(
            AgentPresetCatalog.inferredPresetID(from: runners, org: org),
            "claude-code"
        )
    }

    func testInferredPresetIDWhenNodesBoundToDemo() {
        let runners = SeedTemplate.defaultRunners()
        let org = SeedTemplate.plannerImplementerReviewer(
            runnerName: "echo_fixture",
            agentKind: .custom
        )
        XCTAssertEqual(
            AgentPresetCatalog.inferredPresetID(from: runners, org: org),
            "demo"
        )
    }

    func testInferredPresetIDNilWhenMixedRunnersHaveNoMajority() throws {
        var runners = try AgentPresetCatalog.applying(presetID: "claude-code", to: RunnersConfig())
        runners = try AgentPresetCatalog.applying(presetID: "codex", to: runners)
        var org = SeedTemplate.plannerImplementerReviewer(
            runnerName: "claude_code",
            agentKind: .claudeCode
        )
        // Two Claude, one Codex → majority Claude
        XCTAssertEqual(
            AgentPresetCatalog.inferredPresetID(from: runners, org: org),
            "claude-code"
        )
        // One each of three → no majority
        org.nodes[0].runner = "claude_code"
        org.nodes[1].runner = "codex"
        org.nodes[2].runner = "echo_fixture"
        XCTAssertNil(AgentPresetCatalog.inferredPresetID(from: runners, org: org))
    }
}
