import Foundation
import XCTest
@testable import GraphicalCLI

final class AgentProbeServiceTests: XCTestCase {
    func testFindsExecutableOnInheritedPathAndReturnsVersion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try makeExecutable(named: "claude", in: bin)

        let executor = FakeProbeExecutor(
            result: ProcessResult(exitCode: 0, stdout: "claude 1.2.3\n", stderr: "")
        )
        let service = AgentProbeService(
            processExecutor: executor,
            environment: ["PATH": bin.path, "HOME": root.path],
            homeDirectory: root,
            fileManager: ExecutableAllowlistFileManager(
                allowedPaths: [bin.appendingPathComponent("claude").path]
            )
        )

        let status = try await service.probe(presetID: AgentPresetCatalog.claudeCode.id)

        XCTAssertEqual(status, .installed(version: "claude 1.2.3"))
        let invocation = try XCTUnwrap(executor.invocations.first)
        XCTAssertEqual(invocation.command, bin.appendingPathComponent("claude").path)
        XCTAssertEqual(invocation.arguments, ["--version"])
        XCTAssertEqual(invocation.timeoutSeconds, AgentProbeService.defaultTimeoutSeconds)
        XCTAssertTrue(invocation.inheritEnvironment)
    }

    func testSearchesHomeLocalBinInAdditionToPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localBin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try makeExecutable(named: "cursor-agent", in: localBin)

        let executor = FakeProbeExecutor(
            result: ProcessResult(exitCode: 0, stdout: "", stderr: "cursor-agent 9.0")
        )
        let service = AgentProbeService(
            processExecutor: executor,
            environment: ["PATH": "/usr/bin", "HOME": root.path],
            homeDirectory: root,
            fileManager: ExecutableAllowlistFileManager(
                allowedPaths: [localBin.appendingPathComponent("cursor-agent").path]
            )
        )

        let status = try await service.probe(presetID: AgentPresetCatalog.cursorAgent.id)

        XCTAssertEqual(status, .installed(version: "cursor-agent 9.0"))
        XCTAssertEqual(
            executor.invocations.first?.command,
            localBin.appendingPathComponent("cursor-agent").path
        )
    }

    func testDemoIsAlwaysInstalledAndMissingBinaryDoesNotRunProcess() async throws {
        let executor = FakeProbeExecutor(
            result: ProcessResult(exitCode: 0, stdout: "unused", stderr: "")
        )
        let service = AgentProbeService(
            processExecutor: executor,
            environment: ["PATH": "", "HOME": "/nonexistent"],
            homeDirectory: URL(fileURLWithPath: "/nonexistent"),
            fileManager: ExecutableAllowlistFileManager(allowedPaths: [])
        )

        let demoStatus = try await service.probe(presetID: AgentPresetCatalog.demo.id)
        let codexStatus = try await service.probe(presetID: AgentPresetCatalog.codex.id)
        XCTAssertEqual(demoStatus, .installed(version: "Built in"))
        XCTAssertEqual(codexStatus, .missing)
        XCTAssertTrue(executor.invocations.isEmpty)
    }

    func testNonzeroProbeIsFailedAndUnknownPresetIsRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(named: "codex", in: root)
        let executor = FakeProbeExecutor(
            result: ProcessResult(exitCode: 7, stdout: "", stderr: "not configured")
        )
        let service = AgentProbeService(
            processExecutor: executor,
            environment: ["PATH": root.path, "HOME": root.path],
            homeDirectory: root,
            fileManager: ExecutableAllowlistFileManager(
                allowedPaths: [root.appendingPathComponent("codex").path]
            )
        )

        let status = try await service.probe(presetID: AgentPresetCatalog.codex.id)
        XCTAssertEqual(status, .failed)
        do {
            _ = try await service.probe(presetID: "my-custom-command")
            XCTFail("Expected unknown preset to be rejected")
        } catch {
            XCTAssertEqual(error as? AgentProbeError, .unknownPreset("my-custom-command"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}

private final class ExecutableAllowlistFileManager: FileManager {
    private let allowedPaths: Set<String>

    init(allowedPaths: Set<String>) {
        self.allowedPaths = allowedPaths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        allowedPaths.contains(path)
    }
}

private final class FakeProbeExecutor: ProcessExecuting, @unchecked Sendable {
    struct Invocation {
        let command: String
        let arguments: [String]
        let timeoutSeconds: Int
        let inheritEnvironment: Bool
    }

    private let lock = NSLock()
    private let result: ProcessResult
    private var recordedInvocations: [Invocation] = []

    init(result: ProcessResult) {
        self.result = result
    }

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool
    ) async throws -> ProcessResult {
        lock.withLock {
            recordedInvocations.append(
                Invocation(
                    command: command,
                    arguments: arguments,
                    timeoutSeconds: timeoutSeconds,
                    inheritEnvironment: inheritEnvironment
                )
            )
        }
        return result
    }

    func cancelCurrent() {}
}
