import Foundation
@preconcurrency import Yams

/// Encode/decode runner argv for the Agents editor, and repair templates corrupted by
/// treating multiline `bash -lc` script bodies as one-arg-per-line.
public enum RunnerArgsEditing {
    /// One logical argv element per line when every element is single-line; otherwise a
    /// YAML list so embedded newlines (shell scripts) survive Apply.
    public static func encodeForEditor(_ args: [String]) -> String {
        if args.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) {
            return args.joined(separator: "\n")
        }
        do {
            return try YAMLEncoder().encode(args)
        } catch {
            // Last resort: keep a recoverable two-line shape rather than shredding.
            return args.map { $0.replacingOccurrences(of: "\n", with: "\\n") }
                .joined(separator: "\n")
        }
    }

    public static func decodeFromEditor(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeYAMLList(trimmed),
           let decoded = try? YAMLDecoder().decode([String].self, from: text) {
            return decoded
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Re-join script fragments when a shell `-c`/`-lc` body was shredded into one line
    /// per script line (Agents "one per line" Apply bug).
    public static func repairingShreddedShellScript(_ template: RunnerTemplate) -> RunnerTemplate {
        guard ShellInvocation.isShellInterpreter(command: template.command),
              let flag = template.args.first,
              ShellInvocation.isShellCommandFlag(flag),
              template.args.count > 2
        else {
            return template
        }
        var repaired = template
        repaired.args = [flag, template.args.dropFirst().joined(separator: "\n")]
        return repaired
    }

    public static func repairingShreddedShellScripts(_ runners: RunnersConfig) -> RunnersConfig {
        RunnersConfig(
            runners: runners.runners.mapValues(repairingShreddedShellScript)
        )
    }

    private static func looksLikeYAMLList(_ text: String) -> Bool {
        guard let first = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else {
            return false
        }
        // Sequence entries are `- value` or `-` / `-|` / `->` block indicators — not flags like `-p`.
        return first == "-"
            || first.hasPrefix("- ")
            || first.hasPrefix("-|")
            || first.hasPrefix("->")
            || first.hasPrefix("- >")
            || first.hasPrefix("- |")
    }
}
