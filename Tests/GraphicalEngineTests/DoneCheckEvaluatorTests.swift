import XCTest
@testable import GraphicalDomain
@testable import GraphicalEngine
@testable import GraphicalCLI

/// Dedicated characterization tests for `DoneCheckEvaluator` (plans/012).
/// Covers artifact/shell/router_next check kinds, path escape rejection (plan 004),
/// and empty-group fail-closed behavior (plan 007) in isolation from the full
/// `RunEngine` vertical slice.
final class DoneCheckEvaluatorTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-donecheck-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Artifact checks

    func testArtifactCheckFailsWhenFileMissing() async throws {
        let root = try makeTempDir("artifact-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.artifact("missing.md")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].passed)
        XCTAssertTrue(results[0].detail.contains("Missing or empty"))
    }

    func testArtifactCheckFailsWhenFileEmpty() async throws {
        let root = try makeTempDir("artifact-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyFile = root.appendingPathComponent("empty.md")
        try Data().write(to: emptyFile)

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.artifact("empty.md")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertFalse(results[0].passed)
        XCTAssertTrue(results[0].detail.contains("Missing or empty"))
    }

    func testArtifactCheckPassesWhenFileNonEmpty() async throws {
        let root = try makeTempDir("artifact-nonempty")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plan.md")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.artifact("plan.md")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertTrue(passed)
        XCTAssertTrue(results[0].passed)
        XCTAssertEqual(results[0].detail, file.path)
    }

    func testArtifactCheckRejectsPathEscape() async throws {
        let root = try makeTempDir("artifact-escape")
        let nodeArtifacts = root.appendingPathComponent("artifacts/run1/node1", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeArtifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let secret = nodeArtifacts.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try "leaked".write(to: secret, atomically: true, encoding: .utf8)

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.artifact("../secret.txt")]),
            nodeArtifacts: nodeArtifacts,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertEqual(results[0].detail, "Path escapes node artifacts")
    }

    // MARK: - router_next

    func testRouterNextPassesFromParameter() async throws {
        let root = try makeTempDir("router-param")
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.routerNext]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: RouterNext(nodeId: "implementer", reason: "plan ready")
        )
        XCTAssertTrue(passed)
        XCTAssertEqual(results[0].name, "router_next")
        XCTAssertTrue(results[0].detail.contains("implementer"))
    }

    func testRouterNextPassesFromNextJSONOnDisk() async throws {
        let root = try makeTempDir("router-disk")
        defer { try? FileManager.default.removeItem(at: root) }
        let nextJSON = root.appendingPathComponent("next.json")
        try #"{"node_id":"reviewer","reason":"needs review"}"#.write(
            to: nextJSON, atomically: true, encoding: .utf8
        )

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.routerNext]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertTrue(passed)
        XCTAssertTrue(results[0].detail.contains("reviewer"))
    }

    func testRouterNextFailsWhenNeitherParameterNorFilePresent() async throws {
        let root = try makeTempDir("router-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.routerNext]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertTrue(results[0].detail.contains("Missing next.json"))
    }

    // MARK: - Empty group (plan 007)

    func testEmptyAllOfGroupFailsClosed() async throws {
        let root = try makeTempDir("empty-allof")
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.detail, "Empty done-check group")
    }

    func testEmptyAnyOfGroupFailsClosed() async throws {
        let root = try makeTempDir("empty-anyof")
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .anyOf([]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.detail, "Empty done-check group")
    }

    // MARK: - Shell checks (stub ProcessExecuting)

    func testShellCheckPassesWhenStubReturnsExitZero() async throws {
        let root = try makeTempDir("shell-pass")
        defer { try? FileManager.default.removeItem(at: root) }

        let stub = StubProcessExecuting(result: ProcessResult(exitCode: 0, stdout: "ok", stderr: ""))
        let evaluator = DoneCheckEvaluator(processRunner: stub)
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.shell("true")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertTrue(passed)
        XCTAssertEqual(results[0].detail, "exit 0")
    }

    func testShellCheckFailsWhenStubReturnsNonZero() async throws {
        let root = try makeTempDir("shell-fail")
        defer { try? FileManager.default.removeItem(at: root) }

        let stub = StubProcessExecuting(
            result: ProcessResult(exitCode: 1, stdout: "", stderr: "boom")
        )
        let evaluator = DoneCheckEvaluator(processRunner: stub)
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.shell("false")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertTrue(results[0].detail.contains("exit 1"))
        XCTAssertTrue(results[0].detail.contains("boom"))
    }

    func testShellCheckFailsWhenProcessThrows() async throws {
        let root = try makeTempDir("shell-throws")
        defer { try? FileManager.default.removeItem(at: root) }

        let stub = StubProcessExecuting(error: ProcessRunnerError.launchFailed("no such command"))
        let evaluator = DoneCheckEvaluator(processRunner: stub)
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.shell("nonexistent-command")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertFalse(results[0].detail.isEmpty)
    }

    // MARK: - anyOf semantics across mixed results

    func testAnyOfGroupPassesWhenAtLeastOneCheckPasses() async throws {
        let root = try makeTempDir("anyof-mixed")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("present.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .anyOf([.artifact("missing.md"), .artifact("present.md")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertTrue(passed)
        XCTAssertEqual(results.count, 2)
    }
}

/// Test-only fake for `ProcessExecuting`, per plans/012's suggested pattern:
/// a struct stub returning a fixed `ProcessResult` (or throwing a fixed error)
/// regardless of the command invoked.
private struct StubProcessExecuting: ProcessExecuting {
    var result: ProcessResult?
    var error: Error?

    init(result: ProcessResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool
    ) async throws -> ProcessResult {
        if let error {
            throw error
        }
        return result!
    }

    func cancelCurrent() {}
}
