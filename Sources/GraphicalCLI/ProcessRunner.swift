import Foundation
import GraphicalDomain

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { !timedOut && exitCode == 0 }
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
}

public protocol ProcessExecuting: Sendable {
    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int
    ) async throws -> ProcessResult
}

public struct ProcessRunner: ProcessExecuting {
    public init() {}

    public func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runSync(
                        command: command,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        timeoutSeconds: timeoutSeconds
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
        timeoutSeconds: Int
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

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBox.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBox.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let deadline = timeoutSeconds > 0
            ? Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            : Date.distantFuture
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                // Give it a moment, then force-kill if needed
                let killDeadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.interrupt()
                }
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
        stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
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
        timeoutSeconds: Int
    ) async throws -> ProcessResult {
        let rendered = TemplateRenderer.render(runner: template, context: context)
        return try await processRunner.run(
            command: rendered.command,
            arguments: rendered.args,
            workingDirectory: rendered.cwd,
            environment: rendered.env,
            timeoutSeconds: timeoutSeconds
        )
    }
}
