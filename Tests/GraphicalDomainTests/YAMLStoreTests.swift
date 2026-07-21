import XCTest
@testable import GraphicalDomain

final class YAMLStoreTests: XCTestCase {
    func testSeedRoundTrip() throws {
        let store = YAMLStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try store.createProject(at: root, name: "Demo", seedTemplate: true)
        XCTAssertEqual(created.config.name, "Demo")
        XCTAssertEqual(created.org.nodes.count, 3)
        XCTAssertEqual(created.org.entry, "planner")
        XCTAssertNotNil(created.runners.runners["echo_fixture"])

        let loaded = try store.load(from: root)
        XCTAssertEqual(loaded, created)

        let yaml = try store.encodeToString(created.org)
        let decoded: OrgGraph = try store.decodeFromString(OrgGraph.self, string: yaml)
        XCTAssertEqual(decoded.nodes.map(\.id), created.org.nodes.map(\.id))
    }

    func testHandoffFilterWithholds() {
        let contract = HandoffContract(
            summary: "hello",
            artifacts: ["/tmp/a"],
            checks: [CheckResult(name: "a", passed: true)],
            next: RouterNext(nodeId: "implementer", reason: "go"),
            notes: "secret"
        )
        let filtered = contract.filtered(passing: [.summary, .artifacts])
        XCTAssertEqual(filtered.passed.summary, "hello")
        XCTAssertEqual(filtered.passed.artifacts, ["/tmp/a"])
        XCTAssertTrue(filtered.passed.checks.isEmpty)
        XCTAssertNil(filtered.passed.next)
        XCTAssertNil(filtered.passed.notes)
        XCTAssertTrue(filtered.withheld.contains(.checks))
        XCTAssertTrue(filtered.withheld.contains(.next))
        XCTAssertTrue(filtered.withheld.contains(.notes))
    }

    func testOrgValidatorCatchesUnknownRunner() {
        var org = SeedTemplate.plannerImplementerReviewer()
        org.nodes[0].runner = "missing"
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.contains { if case .unknownRunner = $0 { return true }; return false })
    }

    func testOrgValidatorRouterAllowlist() {
        var org = SeedTemplate.plannerImplementerReviewer()
        org.edges[0].targets = ["nope"]
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.contains { if case .routerTargetUnknown = $0 { return true }; return false })
    }

    func testRunnerTemplateKindAndDefaultModelRoundTrip() throws {
        let store = YAMLStore()
        let template = RunnerTemplate(
            command: "claude",
            args: ["-p", "{{prompt_file}}", "--model", "{{model}}"],
            cwd: "{{project_root}}",
            kind: .claudeCode,
            defaultModel: "sonnet"
        )
        let yaml = try store.encodeToString(template)
        let decoded: RunnerTemplate = try store.decodeFromString(RunnerTemplate.self, string: yaml)
        XCTAssertEqual(decoded, template)
        XCTAssertTrue(yaml.contains("kind: claude_code"))
        XCTAssertTrue(yaml.contains("default_model: sonnet"))
    }

    func testRunnerTemplateMissingKindDefaultsToCustom() throws {
        let store = YAMLStore()
        let yaml = """
        command: /bin/echo
        args:
          - hello
        """
        let decoded: RunnerTemplate = try store.decodeFromString(RunnerTemplate.self, string: yaml)
        XCTAssertEqual(decoded.kind, .custom)
        XCTAssertNil(decoded.defaultModel)
    }

    func testEffectiveModelPrefersNodeOverride() {
        let template = RunnerTemplate(
            command: "claude",
            kind: .claudeCode,
            defaultModel: "sonnet"
        )
        XCTAssertEqual(template.effectiveModel(nodeModel: "opus"), "opus")
        XCTAssertEqual(template.effectiveModel(nodeModel: nil), "sonnet")
        XCTAssertEqual(template.effectiveModel(nodeModel: ""), "sonnet")
        XCTAssertNil(
            RunnerTemplate(command: "echo", kind: .custom).effectiveModel(nodeModel: nil)
        )
    }

    func testSeedClaudeAgentHasKindAndDefaultModel() {
        let runners = SeedTemplate.defaultRunners()
        let claude = runners.runners["claude_code"]
        XCTAssertEqual(claude?.kind, .claudeCode)
        XCTAssertEqual(claude?.defaultModel, "sonnet")
        XCTAssertTrue(claude?.args.contains("--model") == true)
        XCTAssertTrue(claude?.args.contains("{{model}}") == true)
        XCTAssertEqual(runners.runners["echo_fixture"]?.kind, .custom)
        let cursor = runners.runners["cursor_agent"]
        XCTAssertEqual(cursor?.kind, .cursorAgent)
        XCTAssertEqual(cursor?.defaultModel, "composer-2.5-fast")
    }
}
