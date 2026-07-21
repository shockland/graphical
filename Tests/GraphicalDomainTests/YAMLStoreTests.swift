import XCTest
@testable import GraphicalDomain

final class YAMLStoreTests: XCTestCase {
    func testSeedRoundTrip() throws {
        let store = YAMLStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try store.createProject(at: root, name: "Demo", seed: .agenticMesh)
        XCTAssertEqual(created.config.name, "Demo")
        XCTAssertEqual(created.config.meshWidth, 3)
        // entry + 3×(planner,interpreter) + auditor + implementer + report = 10
        XCTAssertEqual(created.org.nodes.count, 10)
        XCTAssertEqual(created.org.entry, "entry")
        XCTAssertTrue(created.org.edges.contains { $0.type == .fanOut })
        XCTAssertTrue(created.org.edges.contains { $0.type == .join })
        XCTAssertNotNil(created.runners.runners["echo_fixture"])

        let loaded = try store.load(from: root)
        XCTAssertEqual(loaded, created)

        let yaml = try store.encodeToString(created.org)
        let decoded: OrgGraph = try store.decodeFromString(OrgGraph.self, string: yaml)
        XCTAssertEqual(decoded.nodes.map(\.id), created.org.nodes.map(\.id))
    }

    func testCreateProjectHonorsMeshWidth() throws {
        let store = YAMLStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-mesh-w-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try store.createProject(at: root, name: "Wide", seed: .agenticMesh, meshWidth: 4)
        XCTAssertEqual(created.config.meshWidth, 4)
        XCTAssertEqual(created.org.nodes.filter { $0.id.hasPrefix("planner-") }.count, 4)
        XCTAssertEqual(created.org.nodes.filter { $0.id.hasPrefix("interpreter-") }.count, 4)
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

    // MARK: - PathSafety

    func testPathSafetyResolveContainedAllowsSimpleRelativePath() {
        let base = URL(fileURLWithPath: "/tmp/graphical-base")
        let resolved = PathSafety.resolveContained(base: base, relative: "plan.md")
        XCTAssertEqual(resolved?.path, "/tmp/graphical-base/plan.md")
    }

    func testPathSafetyResolveContainedAllowsNestedSubdirectory() {
        let base = URL(fileURLWithPath: "/tmp/graphical-base")
        let resolved = PathSafety.resolveContained(base: base, relative: "sub/dir/file.txt")
        XCTAssertEqual(resolved?.path, "/tmp/graphical-base/sub/dir/file.txt")
    }

    func testPathSafetyResolveContainedRejectsParentEscape() {
        let base = URL(fileURLWithPath: "/tmp/graphical-base")
        XCTAssertNil(PathSafety.resolveContained(base: base, relative: "../escape.txt"))
    }

    func testPathSafetyResolveContainedRejectsNestedParentEscape() {
        let base = URL(fileURLWithPath: "/tmp/graphical-base")
        XCTAssertNil(PathSafety.resolveContained(base: base, relative: "node/../../escape.txt"))
    }

    func testPathSafetyResolveContainedRejectsAbsolutePath() {
        let base = URL(fileURLWithPath: "/tmp/graphical-base")
        XCTAssertNil(PathSafety.resolveContained(base: base, relative: "/etc/passwd"))
    }

    func testPathSafetyResolveContainedRejectsEmptyAndNullByte() {
        let base = URL(fileURLWithPath: "/tmp/graphical-base")
        XCTAssertNil(PathSafety.resolveContained(base: base, relative: ""))
        XCTAssertNil(PathSafety.resolveContained(base: base, relative: "a\0b"))
    }

    func testPathSafetyIsSafeNodeIdAcceptsAllowlistedCharacters() {
        XCTAssertTrue(PathSafety.isSafeNodeId("planner"))
        XCTAssertTrue(PathSafety.isSafeNodeId("node-1_2.3"))
    }

    func testPathSafetyIsSafeNodeIdRejectsTraversalAndSeparators() {
        XCTAssertFalse(PathSafety.isSafeNodeId(""))
        XCTAssertFalse(PathSafety.isSafeNodeId("."))
        XCTAssertFalse(PathSafety.isSafeNodeId(".."))
        XCTAssertFalse(PathSafety.isSafeNodeId("a/b"))
        XCTAssertFalse(PathSafety.isSafeNodeId("a\\b"))
        XCTAssertFalse(PathSafety.isSafeNodeId("../etc"))
    }

    func testOrgValidatorSeedNodeIdsAreSafe() {
        let issues = OrgValidator.validate(
            org: SeedTemplate.plannerImplementerReviewer(),
            runners: SeedTemplate.defaultRunners()
        )
        XCTAssertFalse(issues.contains { if case .unsafeNodeId = $0 { return true }; return false })
    }

    func testOrgValidatorRejectsUnsafeNodeId() {
        var org = SeedTemplate.plannerImplementerReviewer()
        org.nodes[0].id = "../escape"
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.contains { if case .unsafeNodeId = $0 { return true }; return false })
    }

    func testOrgValidatorFlagsEmptyDoneChecks() {
        var org = SeedTemplate.plannerImplementerReviewer()
        org.nodes[0].done = .allOf([])
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.contains { if case .emptyDoneChecks(let nodeId) = $0 { return nodeId == "planner" }; return false })
    }

    func testOrgValidatorSeedHasNoEmptyDoneChecks() {
        let issues = OrgValidator.validate(
            org: SeedTemplate.plannerImplementerReviewer(),
            runners: SeedTemplate.defaultRunners()
        )
        XCTAssertFalse(issues.contains { if case .emptyDoneChecks = $0 { return true }; return false })
    }

    func testEnsureGoalFileRejectsEscapingPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-goalfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        XCTAssertThrowsError(
            try store.createProject(at: root, name: "Escape", seed: .none, goalFile: "../escape.md")
        ) { error in
            XCTAssertEqual(error as? YAMLStoreError, .unsafeGoalFile("../escape.md"))
        }
    }

    // MARK: - Goal file source (plans/014)

    func testLoadGoalTextReturnsFileBodyAfterCreateProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-goaltext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let project = try store.createProject(at: root, name: "GoalText", seed: .none)

        let goalText = try store.loadGoalText(projectRoot: root, config: project.config)
        XCTAssertEqual(project.config.goal, "")
        XCTAssertEqual(goalText, "")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("GOAL.md"), encoding: .utf8),
            ""
        )
    }

    func testWriteGoalTextRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-goalwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let project = try store.createProject(at: root, name: "GoalWrite", seed: .none)

        try store.writeGoalText("Ship the feature end to end.", projectRoot: root, config: project.config)
        let reloaded = try store.loadGoalText(projectRoot: root, config: project.config)
        XCTAssertEqual(reloaded, "Ship the feature end to end.")
    }

    func testLoadGoalTextReturnsNilWhenGoalFileMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-goalmissing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let config = ProjectConfig(name: "NoGoalFile", goalFile: "GOAL.md")
        let goalText = try store.loadGoalText(projectRoot: root, config: config)
        XCTAssertNil(goalText, "Expected nil when goalFile is configured but does not exist on disk")
    }

    func testLoadGoalTextReturnsNilWhenGoalFileUnset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-goalunset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let config = ProjectConfig(name: "NoGoalFile", goalFile: nil)
        let goalText = try store.loadGoalText(projectRoot: root, config: config)
        XCTAssertNil(goalText)

        // writeGoalText should also no-op rather than throw when goalFile is unset.
        try store.writeGoalText("ignored", projectRoot: root, config: config)
    }

    func testLoadGoalTextRejectsEscapingPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-goalescape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let config = ProjectConfig(name: "Escape", goalFile: "../escape.md")
        XCTAssertThrowsError(try store.loadGoalText(projectRoot: root, config: config)) { error in
            XCTAssertEqual(error as? YAMLStoreError, .unsafeGoalFile("../escape.md"))
        }
        XCTAssertThrowsError(try store.writeGoalText("x", projectRoot: root, config: config)) { error in
            XCTAssertEqual(error as? YAMLStoreError, .unsafeGoalFile("../escape.md"))
        }
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

    func testParameterizedSeedAssignsRunnerAndClearsIncompatibleModels() {
        let cursorSeed = SeedTemplate.plannerImplementerReviewer(
            runnerName: "cursor_agent",
            agentKind: .cursorAgent
        )
        XCTAssertEqual(Set(cursorSeed.nodes.map(\.runner)), ["cursor_agent"])
        XCTAssertTrue(cursorSeed.nodes.allSatisfy { $0.model == nil })

        let claudeSeed = SeedTemplate.plannerImplementerReviewer(
            runnerName: "claude_code",
            agentKind: .claudeCode
        )
        XCTAssertEqual(claudeSeed.nodes.map(\.model), ["opus", "sonnet", "fable"])
    }

    func testNoArgumentSeedPreservesEchoFixtureDemo() {
        let seed = SeedTemplate.plannerImplementerReviewer()
        XCTAssertEqual(Set(seed.nodes.map(\.runner)), ["echo_fixture"])
        XCTAssertEqual(seed.nodes.map(\.model), ["opus", "sonnet", "fable"])
    }

    func testCursorRunnerArgsSurviveYAMLRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-cursor-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        _ = try store.createProject(at: root, name: "RT", seed: .agenticMesh)
        let runners = RunnersConfig(runners: [
            "cursor_agent": SeedTemplate.defaultRunners().runners["cursor_agent"]!
        ])
        try store.saveRunners(runners, projectRoot: root)

        let disk = try String(contentsOf: GraphicalPaths.runnersYAML(projectRoot: root), encoding: .utf8)
        let project = try store.load(from: root)
        let args = try XCTUnwrap(project.runners.runners["cursor_agent"]?.args)
        XCTAssertEqual(
            args.count,
            2,
            "Expected [-lc, script], got \(args.count). Disk:\n\(disk)\nArgs:\n\(args)"
        )
        XCTAssertEqual(args[0], "-lc")
        XCTAssertTrue(args[1].contains("cursor-agent"), args[1])
        XCTAssertTrue(args[1].contains("set -euo pipefail"), args[1])
    }
}