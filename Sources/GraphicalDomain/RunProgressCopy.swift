import Foundation

/// Human-readable run progress for the Run console and status bar.
/// Pure formatting — no I/O — so Domain tests can lock the copy.
public struct RunProgressCopy: Equatable, Sendable {
    /// Primary line, e.g. "Planner is working · attempt 1 of 2 (1 left)".
    public var headline: String
    /// Secondary line, e.g. "Next: Implementer" or nil when not useful.
    public var detail: String?
    /// Compact one-liner for the window status bar.
    public var statusBar: String
    /// Compact one-liner under the Play controls.
    public var runInfo: String

    public init(headline: String, detail: String? = nil, statusBar: String, runInfo: String) {
        self.headline = headline
        self.detail = detail
        self.statusBar = statusBar
        self.runInfo = runInfo
    }

    public var activityText: String {
        if let detail, !detail.isEmpty {
            return "\(headline)\n\(detail)"
        }
        return headline
    }

    public static func make(
        status: RunStatus?,
        activeNodeId: String?,
        phase: String?,
        iteration: Int?,
        org: OrgGraph?,
        knownNextNodeId: String? = nil,
        runId: String? = nil,
        isRunning: Bool
    ) -> RunProgressCopy {
        let role = roleLabel(for: activeNodeId, org: org)
        let attempt = attemptPhrase(iteration: iteration, nodeId: activeNodeId, org: org)
        let next = nextPhrase(
            activeNodeId: activeNodeId,
            org: org,
            knownNextNodeId: knownNextNodeId
        )
        let phaseText = humanizePhase(phase, org: org)

        if status == .awaitingApproval {
            let toRole = roleLabel(for: knownNextNodeId, org: org) ?? "the next step"
            // One line + explicit CTA — this pause waits forever until Approve/Reject;
            // without that hint it reads as a hung run.
            let headline: String
            if let fromRole = role {
                headline = "Paused — approve \(fromRole) → \(toRole) (Approve to continue)"
            } else {
                headline = "Paused — approve handoff to \(toRole) (Approve to continue)"
            }
            let statusBar = "Awaiting approval · \(role.map { "\($0) → " } ?? "")\(toRole)"
            let runInfo = runInfoLine(
                status: "awaiting approval",
                role: role,
                attempt: nil,
                next: "Next: \(toRole)",
                phase: nil,
                runId: runId
            )
            return RunProgressCopy(
                headline: headline,
                detail: nil,
                statusBar: statusBar,
                runInfo: runInfo
            )
        }

        // Terminal statuses win over isRunning. The session may briefly report
        // isRunning=true after the engine has already written .succeeded/.failed
        // (phase "completed" → "finishing"); prefer the outcome, not the spinner.
        if status == .succeeded {
            let headline = "Done — all steps finished"
            let detail = "Open History if you want to inspect handoffs and artifacts"
            return RunProgressCopy(
                headline: headline,
                detail: detail,
                statusBar: "Done — all steps finished",
                runInfo: runInfoLine(
                    status: "succeeded",
                    role: nil,
                    attempt: nil,
                    next: nil,
                    phase: nil,
                    runId: runId
                )
            )
        }
        if status == .failed {
            let at = role.map { " at \($0)" } ?? ""
            let headline = "Run failed\(at)"
            return RunProgressCopy(
                headline: headline,
                detail: "Use Retry Step to try again, or open History to inspect what failed",
                statusBar: "Run failed\(at)",
                runInfo: runInfoLine(
                    status: "failed",
                    role: role,
                    attempt: nil,
                    next: nil,
                    phase: nil,
                    runId: runId
                )
            )
        }
        if status == .cancelled {
            return RunProgressCopy(
                headline: "Run cancelled",
                detail: "Press Play to start again, or Retry Step to resume the last active step",
                statusBar: "Run cancelled",
                runInfo: runInfoLine(
                    status: "cancelled",
                    role: role,
                    attempt: nil,
                    next: nil,
                    phase: nil,
                    runId: runId
                )
            )
        }

        if isRunning {
            let who = role.map { "\($0) is working" } ?? "Working"
            var headParts = [who]
            if let attempt { headParts.append(attempt) }
            if let phaseText { headParts.append(phaseText) }
            let headline = headParts.joined(separator: " · ")
            let statusParts = [who]
            var statusJoined = statusParts
            if let attempt { statusJoined.append(attempt) }
            if let next { statusJoined.append(next) }
            let runInfo = runInfoLine(
                status: "running",
                role: role,
                attempt: attempt,
                next: next,
                phase: phaseText,
                runId: runId
            )
            return RunProgressCopy(
                headline: headline,
                detail: next,
                statusBar: statusJoined.joined(separator: " · "),
                runInfo: runInfo
            )
        }

        // Idle / not yet started (terminal + awaitingApproval handled above).
        return RunProgressCopy(
            headline: "Ready",
            detail: "Enter a goal, then choose Play",
            statusBar: "Ready",
            runInfo: "Ready. Enter a goal, then choose Play."
        )
    }

    // MARK: - Pieces

    private static func roleLabel(for nodeId: String?, org: OrgGraph?) -> String? {
        guard let nodeId else { return nil }
        return org?.node(id: nodeId)?.role ?? nodeId
    }

    private static func attemptPhrase(iteration: Int?, nodeId: String?, org: OrgGraph?) -> String? {
        guard let iteration,
              let nodeId,
              let maxIterations = org?.node(id: nodeId)?.maxIterations,
              maxIterations > 0
        else {
            return nil
        }
        let left = Swift.max(0, maxIterations - iteration)
        if left == 0 {
            return "attempt \(iteration) of \(maxIterations) (last try)"
        }
        if left == 1 {
            return "attempt \(iteration) of \(maxIterations) (1 left)"
        }
        return "attempt \(iteration) of \(maxIterations) (\(left) left)"
    }

    private static func nextPhrase(
        activeNodeId: String?,
        org: OrgGraph?,
        knownNextNodeId: String?
    ) -> String? {
        if let known = knownNextNodeId {
            let label = roleLabel(for: known, org: org) ?? known
            return "Next: \(label)"
        }
        guard let activeNodeId, let org else { return nil }
        let ids = org.successNextNodeIds(from: activeNodeId)
        if ids.isEmpty {
            return "Final step — done after this"
        }
        let labels = ids.map { org.node(id: $0)?.role ?? $0 }
        if labels.count == 1 {
            return "Next: \(labels[0])"
        }
        if labels.count == 2 {
            return "Next: \(labels[0]) or \(labels[1])"
        }
        let head = labels.dropLast().joined(separator: ", ")
        return "Next: \(head), or \(labels.last!)"
    }

    private static func humanizePhase(_ phase: String?, org: OrgGraph?) -> String? {
        guard let phase, !phase.isEmpty else { return nil }
        if phase.hasPrefix("handoff to ") {
            let id = String(phase.dropFirst("handoff to ".count))
            let role = org?.node(id: id)?.role ?? id
            return "handing off to \(role)"
        }
        switch phase {
        case "starting": return "starting"
        case "preparing": return "preparing"
        case "preparing packet": return "preparing work packet"
        case "writing packet": return "writing work packet"
        case "launching agent": return "starting coding tool"
        case "evaluating checks": return "checking if step is done"
        case "awaiting approval": return "waiting for approval"
        case "completed": return "finishing"
        case "cancelling": return "cancelling"
        default:
            return phase
        }
    }

    private static func runInfoLine(
        status: String,
        role: String?,
        attempt: String?,
        next: String?,
        phase: String?,
        runId: String?
    ) -> String {
        var parts: [String] = []
        if let role { parts.append(role) }
        parts.append(status)
        if let attempt { parts.append(attempt) }
        if let next { parts.append(next) }
        if let phase { parts.append(phase) }
        if let runId, !runId.isEmpty {
            parts.append("run \(runId.prefix(8))")
        }
        return parts.joined(separator: " · ")
    }
}
