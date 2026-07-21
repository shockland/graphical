import Foundation
import GraphicalDomain
import GraphicalCLI

public struct DoneCheckEvaluator: Sendable {
    private let processRunner: any ProcessExecuting

    public init(processRunner: any ProcessExecuting = ProcessRunner()) {
        self.processRunner = processRunner
    }

    public func evaluate(
        group: DoneCheckGroup,
        nodeArtifacts: URL,
        projectRoot: URL,
        routerNext: RouterNext?
    ) async -> (passed: Bool, results: [CheckResult]) {
        let checks = group.checks
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
            let url = nodeArtifacts.appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let nonEmpty: Bool
            if exists, !isDir.boolValue, let data = try? Data(contentsOf: url) {
                nonEmpty = !data.isEmpty
            } else {
                nonEmpty = false
            }
            return CheckResult(
                name: "artifact:\(relativePath)",
                passed: nonEmpty,
                detail: nonEmpty ? url.path : "Missing or empty: \(url.path)"
            )

        case .shell(let command):
            do {
                let result = try await processRunner.run(
                    command: "/bin/bash",
                    arguments: ["-lc", command],
                    workingDirectory: nodeArtifacts.path,
                    environment: [:],
                    timeoutSeconds: 120
                )
                return CheckResult(
                    name: "shell:\(command)",
                    passed: result.succeeded,
                    detail: result.succeeded
                        ? String(result.stdout.prefix(500))
                        : "exit \(result.exitCode): \(String(result.stderr.prefix(500)))"
                )
            } catch {
                return CheckResult(
                    name: "shell:\(command)",
                    passed: false,
                    detail: error.localizedDescription
                )
            }

        case .routerNext:
            if let routerNext {
                return CheckResult(
                    name: "router_next",
                    passed: true,
                    detail: "\(routerNext.nodeId): \(routerNext.reason)"
                )
            }
            // Also accept next.json on disk
            let nextURL = nodeArtifacts.appendingPathComponent("next.json")
            if let data = try? Data(contentsOf: nextURL),
               let parsed = try? JSONDecoder().decode(RouterNext.self, from: data) {
                return CheckResult(
                    name: "router_next",
                    passed: true,
                    detail: "\(parsed.nodeId): \(parsed.reason)"
                )
            }
            return CheckResult(
                name: "router_next",
                passed: false,
                detail: "Missing next.json with node_id and reason"
            )
        }
    }
}
