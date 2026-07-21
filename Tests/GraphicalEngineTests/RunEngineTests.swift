import XCTest
@testable import GraphicalDomain
@testable import GraphicalEngine
@testable import GraphicalCLI

final class RunEngineTests: XCTestCase {
    func testVerticalSliceWithApproval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let project = try store.createProject(at: root, name: "Slice", seedTemplate: true)
        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)

        let first = try await engine.start(project: project, goal: "Build a vertical slice")
        XCTAssertEqual(first.status, .awaitingApproval)

        let pending = await engine.pendingApproval
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.inspection.toNode, "implementer")
        XCTAssertFalse(pending!.inspection.passed.summary.isEmpty)

        let finished = try await engine.approve()
        let events = try await trace.events(runId: finished.id)
        XCTAssertEqual(
            finished.status,
            .succeeded,
            "Expected success, events: \(events.map(\.message))"
        )

        XCTAssertTrue(events.contains { $0.kind == .runStarted })
        XCTAssertTrue(events.contains { $0.kind == .awaitingApproval })
        XCTAssertTrue(events.contains { $0.kind == .approved })
        XCTAssertTrue(events.contains { $0.kind == .routed })
        XCTAssertTrue(events.contains { $0.kind == .runSucceeded })

        let plan = GraphicalPaths.nodeArtifacts(projectRoot: root, runId: finished.id, nodeId: "planner")
            .appendingPathComponent("plan.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))

        let json = try await trace.exportTraceJSON(runId: finished.id)
        XCTAssertFalse(json.isEmpty)
    }

    func testRouterRejectsUnknownTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-bad-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "Bad", seedTemplate: true)
        project.runners.runners["echo_fixture"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                OUT="{{node_artifacts}}"
                mkdir -p "$OUT"
                echo plan > "$OUT/plan.md"
                printf '%s\\n' '{"node_id":"ghost","reason":"bad"}' > "$OUT/next.json"
                """
            ],
            cwd: "{{project_root}}"
        )

        let engine = RunEngine(store: try TraceStore(inMemory: true))
        do {
            _ = try await engine.start(project: project, goal: "x")
            XCTFail("Expected router allowlist failure")
        } catch let error as RunEngineError {
            XCTAssertEqual(error, .routerTargetNotAllowed("ghost"))
        }
    }

    func testTemplateRenderer() {
        let context = RunnerContext(
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            promptFile: URL(fileURLWithPath: "/tmp/packet.md"),
            nodeArtifacts: URL(fileURLWithPath: "/tmp/out"),
            runArtifacts: URL(fileURLWithPath: "/tmp/run"),
            runId: "r1",
            nodeId: "planner",
            model: "opus"
        )
        let rendered = TemplateRenderer.render("{{project_root}}/{{node_id}}/{{model}}", context: context)
        XCTAssertEqual(rendered, "/tmp/proj/planner/opus")
    }

    func testCancelSetsStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, seedTemplate: true)
        let engine = RunEngine(store: try TraceStore(inMemory: true))
        let run = try await engine.start(project: project, goal: "c")
        XCTAssertEqual(run.status, .awaitingApproval)
        try await engine.cancel()
        let current = await engine.currentRun
        XCTAssertEqual(current?.status, .cancelled)
    }

    func testRejectApprovalFailsRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-reject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, seedTemplate: true)
        let engine = RunEngine(store: try TraceStore(inMemory: true))
        _ = try await engine.start(project: project, goal: "reject me")
        let run = try await engine.rejectApproval(notes: "nope")
        XCTAssertEqual(run.status, .failed)
    }

    /// Live Cursor play against this repo's `.graphical/` config. Opt-in:
    /// `GRAPHICAL_LIVE=1 swift test --filter testLiveCursorPlayOnProject`
    func testLiveCursorPlayOnProject() async throws {
        guard ProcessInfo.processInfo.environment["GRAPHICAL_LIVE"] == "1" else {
            throw XCTSkip("Set GRAPHICAL_LIVE=1 to run the live Cursor play")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try YAMLStore().load(from: root)
        XCTAssertEqual(project.org.node(id: "planner")?.runner, "cursor_agent")
        XCTAssertNotNil(project.runners.agent(named: "cursor_agent"))

        let store = try TraceStore(inMemory: true)
        let engine = RunEngine(store: store)
        let run = try await engine.start(project: project, goal: project.config.goal)
        let log = await engine.liveLog
        let events = try await store.events(runId: run.id)
        XCTAssertEqual(
            run.status,
            .succeeded,
            """
            Live Cursor play failed with status \(run.status). active=\(run.activeNodeId ?? "nil")
            log:
            \(log.joined(separator: "\n"))
            events:
            \(events.map { "\($0.kind.rawValue): \($0.message)" }.joined(separator: "\n"))
            """
        )
    }
}
