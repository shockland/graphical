import Foundation

/// Guards against path traversal when joining user/YAML-controlled strings onto a
/// trusted base directory (artifact paths, `goalFile`, node ids used as directory names).
public enum PathSafety {
    /// Resolves `relative` against `base`, returning `nil` if the result would not be
    /// contained under `base` (e.g. absolute paths, `..` escapes, null bytes, empty
    /// strings). Uses lexical standardization (`standardizedFileURL`) rather than
    /// symlink resolution, so it does not depend on the target existing on disk and is
    /// not fooled by attacker-controlled symlinks planted under `base`.
    public static func resolveContained(base: URL, relative: String) -> URL? {
        guard !relative.isEmpty, !relative.contains("\0") else { return nil }
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return nil }

        let baseStandardized = base.standardizedFileURL
        let candidate = baseStandardized.appendingPathComponent(relative).standardizedFileURL

        let basePath = baseStandardized.path
        let candidatePath = candidate.path
        if candidatePath == basePath { return candidate }
        guard candidatePath.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/") else {
            return nil
        }
        return candidate
    }

    /// Allowlist for node ids used as path components: letters, digits, `.`, `_`, `-`.
    /// Rejects empty ids, `.`, `..`, and anything containing `/` or `\`.
    public static func isSafeNodeId(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        return id.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "_" || char == "-")
        }
    }
}
