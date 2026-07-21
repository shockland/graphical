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

/// How a substitution value is encoded when spliced into a rendered string.
public enum SubstitutionEncoding: Sendable, Equatable {
    /// Insert the raw value with no escaping — correct when the destination consumes
    /// the string directly (argv element passed straight to `Process`, a working
    /// directory path, an environment variable value) rather than re-parsing it as
    /// shell source.
    case literal
    /// Wrap the value in POSIX single quotes (`ShellEscape.singleQuoted`) — required
    /// when the destination is text a shell (`bash -c`/`-lc`) will re-interpret, so a
    /// value containing `"`, backticks, or `$(...)` cannot break out of the intended
    /// word boundary.
    case shellSingleQuoted
}

public enum TemplateRenderer {
    public static func render(
        _ template: String,
        context: RunnerContext,
        encoding: SubstitutionEncoding = .literal
    ) -> String {
        render(template, substitutions: context.substitutions, encoding: encoding)
    }

    public static func render(
        _ template: String,
        substitutions: [String: String],
        encoding: SubstitutionEncoding = .literal
    ) -> String {
        var result = template
        for (key, value) in substitutions {
            let replacement = encoding == .shellSingleQuoted ? ShellEscape.singleQuoted(value) : value
            result = result.replacingOccurrences(of: "{{\(key)}}", with: replacement)
        }
        return result
    }

    /// Renders a runner template's command/args/cwd/env against `context`.
    ///
    /// `args` are shell-single-quote-encoded when `command`+`args` indicate the process
    /// is a shell being handed a script body (`bash`/`sh`, `-c`/`-lc`) — that script text
    /// is re-parsed by the shell, so substitutions must not be able to break out of a
    /// word/quote boundary. `command`, `cwd`, and `env` values are consumed directly by
    /// `Process` (executable path, working directory, environment value) rather than
    /// re-interpreted by a shell, so they stay literal — shell-quoting them would corrupt
    /// the path/value instead of protecting it.
    ///
    /// Templates that rely on this encoding must not additionally hand-quote `{{...}}`
    /// placeholders (e.g. `"{{prompt_file}}"`) in their static script text — the renderer
    /// already supplies a single-quoted word; wrapping that in another layer of quotes
    /// double-escapes and corrupts the value. Use bare `{{prompt_file}}` instead.
    public static func render(
        runner: RunnerTemplate,
        context: RunnerContext
    ) -> (command: String, args: [String], cwd: String?, env: [String: String]) {
        let command = render(runner.command, context: context)
        let argsEncoding: SubstitutionEncoding = ShellInvocation.isShellInterpreterInvocation(
            command: runner.command,
            args: runner.args
        ) ? .shellSingleQuoted : .literal
        let args = runner.args.map { render($0, context: context, encoding: argsEncoding) }
        let cwd = runner.cwd.map { render($0, context: context) }
        var env: [String: String] = [:]
        for (key, value) in runner.env {
            env[key] = render(value, context: context)
        }
        return (command, args, cwd, env)
    }
}
