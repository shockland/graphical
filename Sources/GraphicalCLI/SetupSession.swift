import Foundation
import GraphicalDomain

public struct SetupSession: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case firstRun
        case codingToolOnly
    }

    public enum Step: Int, CaseIterable, Equatable, Sendable {
        case goal
        case codingTool
    }

    public var mode: Mode
    public var goal: String
    /// Planner/interpreter lane count for the agentic-mesh seed (`2…8`).
    public var meshWidth: Int
    /// When true, fan-out planner lanes run concurrently.
    public var parallelFanOut: Bool
    public var selectedPresetID: String?
    private(set) public var currentStep: Step

    public init(
        mode: Mode = .firstRun,
        goal: String = "",
        meshWidth: Int = 3,
        parallelFanOut: Bool = true,
        selectedPresetID: String? = "demo",
        currentStep: Step? = nil
    ) {
        self.mode = mode
        self.goal = goal
        self.meshWidth = max(
            OrgValidator.minMeshWidth,
            min(OrgValidator.maxMeshWidth, meshWidth)
        )
        self.parallelFanOut = parallelFanOut
        self.selectedPresetID = selectedPresetID
        switch mode {
        case .firstRun:
            self.currentStep = currentStep ?? .goal
        case .codingToolOnly:
            self.currentStep = .codingTool
        }
    }

    public var canContinue: Bool {
        switch mode {
        case .codingToolOnly:
            return selectedPresetID != nil
        case .firstRun:
            switch currentStep {
            case .goal:
                return !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .codingTool:
                return selectedPresetID != nil
            }
        }
    }

    public var canGoBack: Bool {
        mode == .firstRun && currentStep != .goal
    }

    /// True when first-run can finish from the coding-tool step (no further wizard pages).
    public var isReadyToFinish: Bool {
        switch mode {
        case .codingToolOnly:
            return canContinue
        case .firstRun:
            return currentStep == .codingTool && canContinue
        }
    }

    @discardableResult
    public mutating func back() -> Bool {
        guard mode == .firstRun,
              let previous = Step(rawValue: currentStep.rawValue - 1) else {
            return false
        }
        currentStep = previous
        return true
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard mode == .firstRun, canContinue,
              let next = Step(rawValue: currentStep.rawValue + 1) else {
            return false
        }
        currentStep = next
        return true
    }
}
