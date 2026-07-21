import Foundation

/// Shell-string escaping for template substitutions that end up inside a `bash -c`/`-lc`
/// script body (see `TemplateRenderer.SubstitutionEncoding`). Blind `{{key}}` replacement
/// into a shell string lets a project path or model name containing `"`, backticks, or
/// `$(...)` break out of quoting and execute arbitrary shell — this closes that hole for
/// substituted values without restricting what a user-authored runner's static script text
/// can do.
public enum ShellEscape {
    /// POSIX single-quote escapes `value`: wraps it in `'...'`, replacing any embedded `'`
    /// with `'\''` (close quote, escaped literal quote, reopen quote). The result is safe
    /// to splice into a POSIX shell command line as a single word, for any input including
    /// empty strings, `$`, backticks, double quotes, and newlines.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
