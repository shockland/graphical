import AppKit
import GraphicalDomain

@MainActor
protocol ProjectGuideViewDelegate: AnyObject {
    func projectGuide(_ guide: ProjectGuideView, didRequest action: ProjectGuideView.Action)
}

@MainActor
final class ProjectGuideView: NSView {
    enum Action {
        case setGoal
        case chooseTool
        case fixWorkflow
        case run
    }

    weak var delegate: ProjectGuideViewDelegate?

    private let stack = NSStackView()
    private var readiness: ProjectReadiness?
    private var projectRoot: URL?
    private var detailsVisible = true
    private var preferredHeight: CGFloat = 48

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.borderStrong.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Theme.controlRadius

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        // Compact floating card — width is owned here so OrgWorkspace can
        // trailing-align without stretching across the canvas.
        NSSize(width: 280, height: preferredHeight)
    }

    override func layout() {
        super.layout()
        updatePreferredHeight()
    }

    func reload(readiness newReadiness: ProjectReadiness, projectRoot newProjectRoot: URL) {
        let standardizedRoot = newProjectRoot.standardizedFileURL
        if projectRoot != standardizedRoot {
            detailsVisible = !newReadiness.isReady
        } else if let previous = readiness {
            if previous.isReady != newReadiness.isReady {
                detailsVisible = !newReadiness.isReady
            }
        } else {
            detailsVisible = !newReadiness.isReady
        }
        projectRoot = standardizedRoot
        readiness = newReadiness
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let readiness else { return }

        addFullWidth(header(for: readiness))
        if detailsVisible {
            let rows = [
                Row(title: "Goal", complete: readiness.goalPresent, action: .setGoal),
                Row(title: "Coding tool", complete: readiness.usableAgentSelected, action: .chooseTool),
                Row(title: "Workflow steps", complete: readiness.graphValid, action: .fixWorkflow),
                Row(title: "First run", complete: readiness.firstRunComplete, action: .run)
            ]
            let firstIncomplete = rows.firstIndex { !$0.complete }
            for (index, row) in rows.enumerated() {
                addFullWidth(rowView(row, isNext: index == firstIncomplete))
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        updatePreferredHeight()
    }

    private func header(for readiness: ProjectReadiness) -> NSView {
        let title = AppKitText.label(
            readiness.isReady ? "Ready to run" : "Workflow readiness",
            style: .section
        )
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [title, spacer]

        if readiness.isReady {
            let run = compactButton(title: "Run", action: #selector(runTapped))
            let toggle = compactButton(
                title: detailsVisible ? "Hide details" : "Expand",
                action: #selector(toggleDetails)
            )
            views.append(contentsOf: [run, toggle])
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private struct Row {
        let title: String
        let complete: Bool
        let action: Action
    }

    private func rowView(_ row: Row, isNext: Bool) -> NSView {
        let title = AppKitText.label(row.title, style: .caption)
        title.font = Theme.bodyFont(ofSize: 11, weight: .medium)
        let status = AppKitText.label(
            row.complete ? "Complete" : (isNext ? "Next step" : "Waiting"),
            style: .caption
        )
        status.textColor = row.complete ? Theme.accent : (isNext ? Theme.warning : Theme.muted)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let summary = NSStackView(views: [title, spacer, status])
        summary.orientation = .horizontal
        summary.alignment = .centerY

        guard isNext else { return summary }

        let explanation = AppKitText.label(explanation(for: row.action), style: .muted)
        explanation.maximumNumberOfLines = 2
        explanation.lineBreakMode = .byWordWrapping
        let action = compactButton(title: actionTitle(for: row.action), action: #selector(actionTapped(_:)))
        action.tag = actionTag(row.action)

        let expanded = NSStackView(views: [summary, explanation, action])
        expanded.orientation = .vertical
        expanded.alignment = .leading
        expanded.spacing = 4
        summary.widthAnchor.constraint(equalTo: expanded.widthAnchor).isActive = true
        explanation.widthAnchor.constraint(equalTo: expanded.widthAnchor).isActive = true
        return expanded
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func updatePreferredHeight() {
        let views = stack.arrangedSubviews
        let contentHeight = views.reduce(CGFloat.zero) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, views.count - 1)) * stack.spacing
        let measured = max(48, ceil(contentHeight + 20))
        guard abs(measured - preferredHeight) > 0.5 else { return }
        preferredHeight = measured
        invalidateIntrinsicContentSize()
    }

    private func compactButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Theme.bodyFont(ofSize: 11, weight: .medium)
        return button
    }

    private func explanation(for action: Action) -> String {
        switch action {
        case .setGoal:
            return "Describe what Planner, Implementer, and Reviewer should accomplish."
        case .chooseTool:
            return "Choose a coding tool that every step can use."
        case .fixWorkflow:
            return "Fix the first issue so Planner → Implementer → Reviewer can run in order."
        case .run:
            return "Run once when you’re ready. You’ll pause after Planner to approve the plan."
        }
    }

    private func actionTitle(for action: Action) -> String {
        switch action {
        case .setGoal: return "Set goal"
        case .chooseTool: return "Choose tool"
        case .fixWorkflow: return "Fix steps"
        case .run: return "Run workflow"
        }
    }

    private func actionTag(_ action: Action) -> Int {
        switch action {
        case .setGoal: return 0
        case .chooseTool: return 1
        case .fixWorkflow: return 2
        case .run: return 3
        }
    }

    @objc private func toggleDetails() {
        detailsVisible.toggle()
        rebuild()
    }

    @objc private func runTapped() {
        delegate?.projectGuide(self, didRequest: .run)
    }

    @objc private func actionTapped(_ sender: NSButton) {
        let action: Action
        switch sender.tag {
        case 0: action = .setGoal
        case 1: action = .chooseTool
        case 2: action = .fixWorkflow
        default: action = .run
        }
        delegate?.projectGuide(self, didRequest: action)
    }
}
