import Foundation

public enum AgentProbeStatus: Equatable, Sendable {
    case installed(version: String)
    case missing
    case failed
}

public enum AgentProbeError: Error, Equatable, Sendable {
    case unknownPreset(String)
}

/// Bounded installation/version probes for the built-in preset catalog.
///
/// Custom runner command text is never accepted or executed: callers identify a
/// catalog preset by stable id, and this service uses only its canonical probe.
public struct AgentProbeService: @unchecked Sendable {
    public static let defaultTimeoutSeconds = 5

    private let processExecutor: any ProcessExecuting
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let timeoutSeconds: Int

    public init(
        processExecutor: any ProcessExecuting = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default,
        timeoutSeconds: Int = AgentProbeService.defaultTimeoutSeconds
    ) {
        self.processExecutor = processExecutor
        self.environment = environment
        self.homeDirectory = homeDirectory
            ?? environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
        self.fileManager = fileManager
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    public static func searchDirectories(
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        var directories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        directories.append(homeDirectory.appendingPathComponent(".local/bin", isDirectory: true))

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func probe(presetID: String) async throws -> AgentProbeStatus {
        guard let preset = AgentPresetCatalog.preset(id: presetID) else {
            throw AgentProbeError.unknownPreset(presetID)
        }
        guard let probe = preset.probe else {
            return .installed(version: "Built in")
        }
        guard let executable = executableURL(named: probe.command) else {
            return .missing
        }

        let executor = processExecutor
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .failed }
            do {
                let result = try await executor.run(
                    command: executable.path,
                    arguments: probe.arguments,
                    workingDirectory: nil,
                    environment: [
                        "PATH": Self.searchDirectories(
                            environment: environment,
                            homeDirectory: homeDirectory
                        ).map(\.path).joined(separator: ":")
                    ],
                    timeoutSeconds: timeoutSeconds,
                    inheritEnvironment: true
                )
                guard !Task.isCancelled, result.succeeded else { return .failed }
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let versionText = output.isEmpty ? fallback : output
                let firstLine = versionText.split(whereSeparator: \.isNewline).first.map(String.init)
                return .installed(version: firstLine ?? "Installed")
            } catch {
                return .failed
            }
        } onCancel: {
            executor.cancelCurrent()
        }
    }

    public func cancelCurrentProbe() {
        processExecutor.cancelCurrent()
    }

    private func executableURL(named command: String) -> URL? {
        guard !command.isEmpty, !command.contains("/") else { return nil }
        for directory in Self.searchDirectories(
            environment: environment,
            homeDirectory: homeDirectory
        ) {
            let candidate = directory.appendingPathComponent(command, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
