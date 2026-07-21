import Foundation

/// One-shot first-run tip copy + UserDefaults flags (approval gate + History).
public enum FirstRunCoach {
    private static let approvalKey = "graphical.firstRunCoach.approval"
    private static let historyKey = "graphical.firstRunCoach.history"

    public static var defaults: UserDefaults = .standard

    public static var hasSeenApprovalTip: Bool {
        get { defaults.bool(forKey: approvalKey) }
        set { defaults.set(newValue, forKey: approvalKey) }
    }

    public static var hasSeenHistoryTip: Bool {
        get { defaults.bool(forKey: historyKey) }
        set { defaults.set(newValue, forKey: historyKey) }
    }

    /// Copy for the first approval pause. `fromRole` / `toRole` should be display roles
    /// (e.g. Planner / Implementer), not raw node ids.
    public static func approvalTip(fromRole: String, toRole: String) -> String {
        """
        Pause: review what \(fromRole) passes to \(toRole) before work continues.
        Approve continues the run. Reject stops it (different from a Reviewer reject edge, which can send work back to Implementer without ending the run).
        """
    }

    public static let historyTip =
        "This handoff is recorded in History so you can inspect what each step passed forward."

    public static func resetForTests() {
        defaults.removeObject(forKey: approvalKey)
        defaults.removeObject(forKey: historyKey)
    }
}
