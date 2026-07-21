import Foundation

/// Shared classifier for POSIX shell interpreter invocations (`bash`/`sh`/`zsh` with
/// `-c`/`-lc`). Used by runner-arg repair and template rendering so both agree on
/// when argv contains a script body that must be shell-escaped.
public enum ShellInvocation {
    public static let interpreterBasenames: Set<String> = ["bash", "sh", "zsh"]

    public static func executableBasename(of command: String) -> String {
        URL(fileURLWithPath: command).lastPathComponent
    }

    public static func isShellInterpreter(command: String) -> Bool {
        interpreterBasenames.contains(executableBasename(of: command))
    }

    public static func isShellCommandFlag(_ argument: String) -> Bool {
        argument == "-c" || argument == "-lc"
    }

    /// True when `command` is a known shell and `args` includes `-c`/`-lc` (script body
    /// will be re-parsed by the shell rather than passed through as plain argv).
    public static func isShellInterpreterInvocation(command: String, args: [String]) -> Bool {
        guard isShellInterpreter(command: command) else { return false }
        return args.contains(where: isShellCommandFlag)
    }
}
