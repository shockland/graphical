import Foundation
import GraphicalDomain

public struct RunnerContext: Equatable, Sendable {
    public var projectRoot: URL
    public var promptFile: URL
    public var nodeArtifacts: URL
    public var runArtifacts: URL
    public var runId: String
    public var nodeId: String
    public var model: String?
    public var extra: [String: String]

    public init(
        projectRoot: URL,
        promptFile: URL,
        nodeArtifacts: URL,
        runArtifacts: URL,
        runId: String,
        nodeId: String,
        model: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.projectRoot = projectRoot
        self.promptFile = promptFile
        self.nodeArtifacts = nodeArtifacts
        self.runArtifacts = runArtifacts
        self.runId = runId
        self.nodeId = nodeId
        self.model = model
        self.extra = extra
    }

    public var substitutions: [String: String] {
        var map: [String: String] = [
            "project_root": projectRoot.path,
            "prompt_file": promptFile.path,
            "node_artifacts": nodeArtifacts.path,
            "run_artifacts": runArtifacts.path,
            "run_id": runId,
            "node_id": nodeId,
            "model": model ?? ""
        ]
        for (key, value) in extra {
            map[key] = value
        }
        return map
    }
}

public enum TemplateRenderer {
    public static func render(_ template: String, context: RunnerContext) -> String {
        render(template, substitutions: context.substitutions)
    }

    public static func render(_ template: String, substitutions: [String: String]) -> String {
        var result = template
        for (key, value) in substitutions {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    public static func render(runner: RunnerTemplate, context: RunnerContext) -> (command: String, args: [String], cwd: String?, env: [String: String]) {
        let command = render(runner.command, context: context)
        let args = runner.args.map { render($0, context: context) }
        let cwd = runner.cwd.map { render($0, context: context) }
        var env: [String: String] = [:]
        for (key, value) in runner.env {
            env[key] = render(value, context: context)
        }
        return (command, args, cwd, env)
    }
}
