import Foundation
import GraphicalDomain
import GraphicalCLI

public struct DoneCheckEvaluator: Sendable {
    /// Hard cap on `CheckResult.detail` length (plan 011): failure hints (exit code,
    /// short stderr prefix) stay useful for debugging without persisting large bodies.
    public static let maxDetailLength = 200

    private let processRunner: any ProcessExecuting

    public init(processRunner: any ProcessExecuting = ProcessRunner()) {
        self.processRunner = processRunner
    }

    static func capDetail(_ text: String) -> String {
        String(text.prefix(maxDetailLength))
    }

    public func evaluate(
        group: DoneCheckGroup,
        nodeArtifacts: URL,
        projectRoot: URL,
        routerNext: RouterNext?
    ) async -> (passed: Bool, results: [CheckResult]) {
        let checks = group.checks
        if checks.isEmpty {
            return (
                passed: false,
                results: [CheckResult(name: "done", passed: false, detail: "Empty done-check group")]
            )
        }
        var results: [CheckResult] = []
        for check in checks {
            let result = await evaluateOne(
                check: check,
                nodeArtifacts: nodeArtifacts,
                projectRoot: projectRoot,
                routerNext: routerNext
            )
            results.append(result)
        }

        let passed: Bool
        switch group {
        case .allOf:
            passed = results.allSatisfy(\.passed)
        case .anyOf:
            passed = results.contains(where: \.passed) || results.isEmpty
        }
        return (passed, results)
    }

    private func evaluateOne(
        check: DoneCheck,
        nodeArtifacts: URL,
        projectRoot: URL,
        routerNext: RouterNext?
    ) async -> CheckResult {
        switch check {
        case .artifact(let relativePath):
            guard let url = PathSafety.resolveContained(base: nodeArtifacts, relative: relativePath) else {
            return CheckResult(
                name: DoneCheck.artifact(relativePath).displayName,
                passed: false,
                detail: "Path escapes node artifacts"
            )
            }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let nonEmpty: Bool
            if exists, !isDir.boolValue, let data = try? Data(contentsOf: url) {
                nonEmpty = !data.isEmpty
            } else {
                nonEmpty = false
            }
            return CheckResult(
                name: DoneCheck.artifact(relativePath).displayName,
                passed: nonEmpty,
                detail: nonEmpty ? url.path : "Missing or empty: \(url.path)"
            )

        case .shell(let command):
            // Detail is capped and never carries full stdout, even on success — shell
            // checks routinely echo command output that may include secrets, and this
            // detail string ends up in the durable SQLite trace store (plan 011).
            do {
                let result = try await processRunner.run(
                    command: "/bin/bash",
                    arguments: ["-c", command],
                    workingDirectory: nodeArtifacts.path,
                    environment: [:],
                    timeoutSeconds: 120,
                    inheritEnvironment: false
                )
                let detail = result.succeeded
                    ? "exit 0"
                    : Self.capDetail("exit \(result.exitCode): \(result.stderr)")
                return CheckResult(
                    name: DoneCheck.shell(command).displayName,
                    passed: result.succeeded,
                    detail: detail
                )
            } catch {
                return CheckResult(
                    name: DoneCheck.shell(command).displayName,
                    passed: false,
                    detail: Self.capDetail(error.localizedDescription)
                )
            }

        case .routerNext:
            let name = DoneCheck.routerNext.displayName
            if let routerNext {
                return CheckResult(
                    name: name,
                    passed: true,
                    detail: "\(routerNext.nodeId): \(routerNext.reason)"
                )
            }
            if let parsed = NodeArtifacts.loadRouterNext(from: nodeArtifacts) {
                return CheckResult(
                    name: name,
                    passed: true,
                    detail: "\(parsed.nodeId): \(parsed.reason)"
                )
            }
            return CheckResult(
                name: name,
                passed: false,
                detail: "Missing \(NodeArtifacts.nextJSON) with node_id and reason"
            )
        }
    }
}
