import Foundation
import GraphicalDomain

public enum ProcessOutputStream: String, Equatable, Sendable {
    case stdout
    case stderr
}

public struct ProcessOutputChunk: Equatable, Sendable {
    public var stream: ProcessOutputStream
    public var data: Data

    public init(stream: ProcessOutputStream, data: Data) {
        self.stream = stream
        self.data = data
    }

    public var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var cancelled: Bool
    /// `true` if stdout and/or stderr hit the capture cap and were truncated.
    /// Exit-code semantics are unaffected.
    public var truncated: Bool

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        cancelled: Bool = false,
        truncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.truncated = truncated
    }

    public var succeeded: Bool { !timedOut && !cancelled && exitCode == 0 }
}

public enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return message
        case .cancelled: return "Process cancelled"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .launchFailed:
            return "Check that the coding tool binary is installed and on your PATH, or fix the runner command under Agents."
        case .cancelled:
            return nil
        }
    }
}

/// Runs subprocesses; `cancelCurrent()` terminates the active child (no-op when idle).
///
/// `inheritEnvironment` controls the environment starting point: `true` merges
/// `environment` on top of the full host process environment (agent/model-discovery
/// runners); `false` starts from a minimal allowlist (`PATH`, `HOME`, `TMPDIR`,
/// `USER`, `LOGNAME`) before merging `environment` — used for done-checks so they do
/// not inherit host secrets.
public protocol ProcessExecuting: Sendable {
    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool
    ) async throws -> ProcessResult

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool,
        onOutput: @escaping @Sendable (ProcessOutputChunk) async -> Void
    ) async throws -> ProcessResult

    func cancelCurrent()
}

extension ProcessExecuting {
    /// Compatibility path for process executors that do not provide true streaming.
    /// `ProcessRunner` overrides this and delivers chunks while its child is running.
    public func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool,
        onOutput: @escaping @Sendable (ProcessOutputChunk) async -> Void
    ) async throws -> ProcessResult {
        let result = try await run(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            inheritEnvironment: inheritEnvironment
        )
        if !result.stdout.isEmpty {
            await onOutput(ProcessOutputChunk(stream: .stdout, data: Data(result.stdout.utf8)))
        }
        if !result.stderr.isEmpty {
            await onOutput(ProcessOutputChunk(stream: .stderr, data: Data(result.stderr.utf8)))
        }
        return result
    }

    /// Convenience overload preserving the pre-existing call sites' default of
    /// full environment inheritance.
    public func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int
    ) async throws -> ProcessResult {
        try await run(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            inheritEnvironment: true
        )
    }
}

/// Minimal environment allowlist copied from the host process when `inheritEnvironment`
/// is `false`, so isolated subprocesses (done-checks) still resolve a shell and `PATH`.
public enum ProcessEnvironmentAllowlist {
    public static let keys = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME"]

    public static func seed(from hostEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = hostEnvironment[key] {
                result[key] = value
            }
        }
        return result
    }
}

public struct ProcessRunner: ProcessExecuting {
    /// Per-stream cap on buffered stdout/stderr. Beyond this, further bytes are
    /// dropped and `ProcessResult.truncated` is set; exit-code semantics are unaffected.
    public static let maxCaptureBytesPerStream = 512 * 1024

    private let activeProcess = ActiveProcessHandle()

    public init() {}

    public func cancelCurrent() {
        activeProcess.cancelCurrent()
    }

    public func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool
    ) async throws -> ProcessResult {
        try await runCaptured(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            inheritEnvironment: inheritEnvironment,
            emitOutput: nil
        )
    }

    public func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool,
        onOutput: @escaping @Sendable (ProcessOutputChunk) async -> Void
    ) async throws -> ProcessResult {
        let (outputStream, outputContinuation) = AsyncStream<ProcessOutputChunk>.makeStream()
        let outputConsumer = Task {
            for await chunk in outputStream {
                await onOutput(chunk)
            }
        }

        do {
            let result = try await runCaptured(
                command: command,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                inheritEnvironment: inheritEnvironment,
                emitOutput: { chunk in
                    outputContinuation.yield(chunk)
                }
            )
            outputContinuation.finish()
            await outputConsumer.value
            return result
        } catch {
            outputContinuation.finish()
            await outputConsumer.value
            throw error
        }
    }

    private func runCaptured(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool,
        emitOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runSync(
                        command: command,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        timeoutSeconds: timeoutSeconds,
                        inheritEnvironment: inheritEnvironment,
                        handle: activeProcess,
                        emitOutput: emitOutput
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool,
        handle: ActiveProcessHandle,
        emitOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) throws -> ProcessResult {
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        var env = inheritEnvironment ? ProcessInfo.processInfo.environment : ProcessEnvironmentAllowlist.seed()
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBox = DataBox(cap: maxCaptureBytesPerStream)
        let stderrBox = DataBox(cap: maxCaptureBytesPerStream)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                let accepted = stdoutBox.append(data)
                if !accepted.isEmpty {
                    emitOutput?(ProcessOutputChunk(stream: .stdout, data: accepted))
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                let accepted = stderrBox.append(data)
                if !accepted.isEmpty {
                    emitOutput?(ProcessOutputChunk(stream: .stderr, data: accepted))
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        handle.register(process)
        defer { handle.unregister() }

        let deadline = timeoutSeconds > 0
            ? Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            : Date.distantFuture
        var timedOut = false
        var cancelled = false
        while process.isRunning {
            if handle.isCancelled {
                cancelled = true
                handle.terminate(process)
                break
            }
            if Date() > deadline {
                timedOut = true
                handle.terminate(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.waitUntilExit()
        } else if !timedOut {
            // Ensure termination status is available
            process.waitUntilExit()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any remaining buffered bytes
        let finalStdout = stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        if !finalStdout.isEmpty {
            emitOutput?(ProcessOutputChunk(stream: .stdout, data: finalStdout))
        }
        let finalStderr = stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        if !finalStderr.isEmpty {
            emitOutput?(ProcessOutputChunk(stream: .stderr, data: finalStderr))
        }

        let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            cancelled: cancelled,
            truncated: stdoutBox.isTruncated || stderrBox.isTruncated
        )
    }
}

private final class ActiveProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        self.cancelled = false
        lock.unlock()
    }

    func unregister() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancelCurrent() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        guard let proc else { return }
        terminate(proc)
    }

    func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.interrupt()
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var truncated = false
    private let cap: Int

    init(cap: Int) {
        self.cap = cap
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    @discardableResult
    func append(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < cap else {
            truncated = true
            return Data()
        }
        let remaining = cap - storage.count
        if data.count > remaining {
            let accepted = Data(data.prefix(remaining))
            storage.append(accepted)
            truncated = true
            return accepted
        } else {
            storage.append(data)
            return data
        }
    }
}

public struct CLIRunner: Sendable {
    private let processRunner: any ProcessExecuting

    public init(processRunner: any ProcessExecuting = ProcessRunner()) {
        self.processRunner = processRunner
    }

    public func invoke(
        template: RunnerTemplate,
        context: RunnerContext,
        timeoutSeconds: Int,
        onOutput: (@Sendable (ProcessOutputChunk) async -> Void)? = nil
    ) async throws -> ProcessResult {
        let rendered = TemplateRenderer.render(runner: template, context: context)
        if let onOutput {
            return try await processRunner.run(
                command: rendered.command,
                arguments: rendered.args,
                workingDirectory: rendered.cwd,
                environment: rendered.env,
                timeoutSeconds: timeoutSeconds,
                inheritEnvironment: true,
                onOutput: onOutput
            )
        }
        return try await processRunner.run(
            command: rendered.command,
            arguments: rendered.args,
            workingDirectory: rendered.cwd,
            environment: rendered.env,
            timeoutSeconds: timeoutSeconds,
            inheritEnvironment: true
        )
    }
}
