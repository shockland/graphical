import Foundation

/// A derived onboarding/run-readiness snapshot. Nothing here is persisted: callers
/// recompute it from the current project and whether recent runs include a completion.
public struct ProjectReadiness: Equatable, Sendable {
    public enum RecommendedAction: String, Equatable, Sendable {
        case setGoal
        case selectAgent
        case fixGraph
        case runFirstWorkflow
        case none
    }

    public let goalPresent: Bool
    public let usableAgentSelected: Bool
    public let graphValid: Bool
    public let firstRunComplete: Bool
    public let nextRecommendedAction: RecommendedAction

    public var isReady: Bool {
        canRun && firstRunComplete
    }

    /// The project has everything required to start, independent of onboarding history.
    public var canRun: Bool {
        goalPresent && usableAgentSelected && graphValid
    }

    public static func derive(
        goal: String,
        org: OrgGraph,
        runners: RunnersConfig,
        firstRunComplete: Bool
    ) -> ProjectReadiness {
        let goalPresent = !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let usableAgentSelected = !org.nodes.isEmpty && org.nodes.allSatisfy { node in
            guard let runner = runners.runners[node.runner] else { return false }
            return !runner.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let graphValid = OrgValidator.validate(org: org, runners: runners)
            .filter { !$0.isWarning }
            .isEmpty

        let nextAction: RecommendedAction
        if !goalPresent {
            nextAction = .setGoal
        } else if !usableAgentSelected {
            nextAction = .selectAgent
        } else if !graphValid {
            nextAction = .fixGraph
        } else if !firstRunComplete {
            nextAction = .runFirstWorkflow
        } else {
            nextAction = .none
        }

        return ProjectReadiness(
            goalPresent: goalPresent,
            usableAgentSelected: usableAgentSelected,
            graphValid: graphValid,
            firstRunComplete: firstRunComplete,
            nextRecommendedAction: nextAction
        )
    }

    public init(
        goalPresent: Bool,
        usableAgentSelected: Bool,
        graphValid: Bool,
        firstRunComplete: Bool,
        nextRecommendedAction: RecommendedAction
    ) {
        self.goalPresent = goalPresent
        self.usableAgentSelected = usableAgentSelected
        self.graphValid = graphValid
        self.firstRunComplete = firstRunComplete
        self.nextRecommendedAction = nextRecommendedAction
    }
}
