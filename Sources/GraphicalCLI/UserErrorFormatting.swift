import Foundation

/// Joins `LocalizedError` diagnosis + recovery into one user-facing string for
/// status bars and failure strips (plan 018).
public enum UserErrorFormatting {
    /// Prefer `errorDescription` + `recoverySuggestion` when both exist; otherwise
    /// fall back to `localizedDescription`.
    public static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError {
            let diagnosis = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recovery = localized.recoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (diagnosis, recovery) {
            case let (d?, r?) where !d.isEmpty && !r.isEmpty:
                return "\(d) \(r)"
            case let (d?, _) where !d.isEmpty:
                return d
            case let (_, r?) where !r.isEmpty:
                return r
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
