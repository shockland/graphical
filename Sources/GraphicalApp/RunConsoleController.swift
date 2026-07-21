import AppKit
import GraphicalCLI
import GraphicalDomain

@MainActor
final class RunConsoleController: NSObject {
    var model: AppModel!
    let view = NSView()

    private let goalView = NSTextView()
    private let logView = MonoLogView()
    private let runInfo = AppKitText.label("", style: .body)
    private let activityLabel = AppKitText.label("", style: .caption)
    private let activitySpinner = NSProgressIndicator()
    private let activityRow = NSStackView()
    private let playButton: PrimaryButton
    private let cancelButton: PrimaryButton
    private let retryButton: PrimaryButton
    private let approvalBox = NSView()
    private let approvalLabel = AppKitText.label("", style: .body)
    private let approvalCoachLabel = AppKitText.label("", style: .caption)
    private let approveButton: PrimaryButton
    private let rejectButton: PrimaryButton
    private let handoffStack = NSStackView()
    private var pulseLayer: CALayer?
    private var pulseTimer: Timer?
    /// Identity of the last-rendered handoff inspection (plans/013), so repeated
    /// progress ticks with the same pending/last inspection skip tearing down and
    /// rebuilding `handoffStack`'s arranged subviews.
    private var renderedHandoffSignature: String?
    /// Includes coach visibility so tips appear once without requiring a handoff change.
    private var renderedCoachSignature: String?
    /// Sticky for the current approval pause (UserDefaults alone would hide on the next tick).
    private var showApprovalCoachForCurrentPause = false
    /// Sticky for the current handoff panel until History is opened or the handoff clears.
    private var showHistoryCoachForCurrentHandoff = false

    override init() {
        playButton = PrimaryButton(title: "Play", style: .primary, target: nil, action: nil)
        cancelButton = PrimaryButton(title: "Cancel", style: .secondary, target: nil, action: nil)
        retryButton = PrimaryButton(title: "Retry Step", style: .secondary, target: nil, action: nil)
        approveButton = PrimaryButton(title: "Approve", style: .primary, target: nil, action: nil)
        rejectButton = PrimaryButton(title: "Reject", style: .danger, target: nil, action: nil)
        super.init()
        playButton.target = self
        playButton.action = #selector(startRun)
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.imagePosition = .imageLeading
        cancelButton.target = self
        cancelButton.action = #selector(cancelRun)
        retryButton.target = self
        retryButton.action = #selector(retryRun)
        approveButton.target = self
        approveButton.action = #selector(approve)
        rejectButton.target = self
        rejectButton.action = #selector(reject)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor

        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        right.wantsLayer = true
        right.layer?.backgroundColor = Theme.surface.cgColor

        let title = AppKitText.label("Run Console", style: .title)
        let subtitle = AppKitText.label(
            "Runs Planner → Implementer → Reviewer from the entry step using each node’s coding tool.",
            style: .muted
        )
        subtitle.maximumNumberOfLines = 2
        let goalScroll = wrap(goalView, height: 100)
        goalView.isRichText = false
        goalView.font = Theme.bodyFont()
        goalView.delegate = self

        let gitignore = PrimaryButton(title: "Artifacts .gitignore", style: .ghost, target: self, action: #selector(gitignore))
        let buttons = NSStackView(views: [playButton, cancelButton, retryButton, gitignore])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        approvalBox.wantsLayer = true
        approvalBox.layer?.backgroundColor = Theme.warningSoft.cgColor
        approvalBox.layer?.cornerRadius = Theme.controlRadius
        approvalBox.translatesAutoresizingMaskIntoConstraints = false
        approvalLabel.maximumNumberOfLines = 0
        approvalCoachLabel.textColor = Theme.muted
        approvalCoachLabel.maximumNumberOfLines = 0
        approvalCoachLabel.lineBreakMode = .byWordWrapping
        approvalCoachLabel.isHidden = true
        let approvalButtons = NSStackView(views: [approveButton, rejectButton])
        approvalButtons.orientation = .horizontal
        approvalButtons.spacing = 8
        let approvalContent = NSStackView(views: [approvalLabel, approvalCoachLabel, approvalButtons])
        approvalContent.orientation = .vertical
        approvalContent.alignment = .leading
        approvalContent.spacing = 10
        approvalContent.translatesAutoresizingMaskIntoConstraints = false
        approvalBox.addSubview(approvalContent)
        NSLayoutConstraint.activate([
            approvalContent.leadingAnchor.constraint(equalTo: approvalBox.leadingAnchor, constant: 12),
            approvalContent.trailingAnchor.constraint(equalTo: approvalBox.trailingAnchor, constant: -12),
            approvalContent.topAnchor.constraint(equalTo: approvalBox.topAnchor, constant: 12),
            approvalContent.bottomAnchor.constraint(equalTo: approvalBox.bottomAnchor, constant: -12),
            approvalLabel.widthAnchor.constraint(equalTo: approvalContent.widthAnchor),
            approvalCoachLabel.widthAnchor.constraint(equalTo: approvalContent.widthAnchor)
        ])

        let goalLabel = AppKitText.label("Goal", style: .caption)
        goalLabel.textColor = Theme.muted
        let logTitle = AppKitText.label("Live Run & Coding Tool Output", style: .section)
        activitySpinner.style = .spinning
        activitySpinner.controlSize = .small
        activitySpinner.isDisplayedWhenStopped = false
        activitySpinner.translatesAutoresizingMaskIntoConstraints = false
        activityLabel.textColor = Theme.accent
        activityLabel.maximumNumberOfLines = 4
        activityLabel.lineBreakMode = .byWordWrapping
        activityLabel.usesSingleLineMode = false
        activityLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityRow.orientation = .horizontal
        activityRow.alignment = .top
        activityRow.spacing = 8
        activityRow.translatesAutoresizingMaskIntoConstraints = false
        activityRow.addArrangedSubview(activitySpinner)
        activityRow.addArrangedSubview(activityLabel)
        activityRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        activityRow.isHidden = true
        let logHeaderStack = NSStackView(views: [logTitle, activityRow])
        logHeaderStack.orientation = .vertical
        logHeaderStack.alignment = .leading
        logHeaderStack.spacing = 6
        logHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        logHeaderStack.setContentHuggingPriority(.required, for: .vertical)
        let headerStack = NSStackView(views: [
            title, subtitle, goalLabel, goalScroll, buttons, runInfo, approvalBox
        ])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setContentHuggingPriority(.required, for: .vertical)
        headerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        logView.setContentHuggingPriority(.defaultLow, for: .vertical)
        logView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        left.addSubview(headerStack)
        left.addSubview(logHeaderStack)
        left.addSubview(logView)

        let handoffTitle = AppKitText.label("Passed to next step", style: .title)
        handoffStack.orientation = .vertical
        handoffStack.alignment = .leading
        handoffStack.spacing = 10
        handoffStack.translatesAutoresizingMaskIntoConstraints = false
        let rightStack = NSStackView(views: [handoffTitle, handoffStack])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 12
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let handoffScroll = NSScrollView()
        handoffScroll.translatesAutoresizingMaskIntoConstraints = false
        handoffScroll.hasVerticalScroller = true
        handoffScroll.hasHorizontalScroller = false
        handoffScroll.drawsBackground = false
        handoffScroll.borderType = .noBorder
        handoffScroll.documentView = rightStack
        right.addSubview(handoffScroll)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(left)
        view.addSubview(border)
        view.addSubview(right)

        let leftWidth = left.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.58)
        leftWidth.priority = .defaultHigh
        // NSStackView collapses hidden arranged subviews. Keeping this equality
        // required while approvalBox is hidden makes Auto Layout shrink the whole
        // header to its intrinsic width and break its leading-edge constraint.
        let approvalWidth = approvalBox.widthAnchor.constraint(equalTo: headerStack.widthAnchor)
        approvalWidth.priority = .defaultHigh

        let leftMinWidth = left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        leftMinWidth.priority = .defaultHigh
        let logMinHeight = logView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        logMinHeight.priority = .defaultHigh
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        right.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            left.topAnchor.constraint(equalTo: view.topAnchor),
            left.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftMinWidth,
            leftWidth,

            border.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            border.topAnchor.constraint(equalTo: view.topAnchor),
            border.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            right.leadingAnchor.constraint(equalTo: border.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            right.topAnchor.constraint(equalTo: view.topAnchor),
            right.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerStack.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: left.topAnchor, constant: 16),

            logHeaderStack.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
            logHeaderStack.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),
            logHeaderStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),

            logView.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),
            logView.topAnchor.constraint(equalTo: logHeaderStack.bottomAnchor, constant: 8),
            logView.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -16),
            logMinHeight,

            handoffScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            handoffScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            handoffScroll.topAnchor.constraint(equalTo: right.topAnchor),
            handoffScroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),

            rightStack.widthAnchor.constraint(equalTo: handoffScroll.widthAnchor),

            goalScroll.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            approvalWidth,
            handoffStack.widthAnchor.constraint(equalTo: rightStack.widthAnchor, constant: -32)
        ])
    }

    /// Full reload: tab entry, project switch, focus-goal, or any non-progress
    /// change. Replaces the log wholesale and re-syncs the goal editor.
    func reload() {
        if goalView.window?.firstResponder !== goalView,
           goalView.string != model.goalDraft {
            goalView.string = model.goalDraft
        }
        if model.focusRunGoal {
            model.consumeFocusRunGoal()
            view.window?.makeFirstResponder(goalView)
        }
        updateRunInfo()
        updateActivity()
        logView.setLines(model.liveLog)
        updateControls()
        updateApprovalBox()
        rebuildHandoffIfChanged(model.lastInspection ?? model.pendingApproval?.inspection)
        updatePulse(model.isRunning)
    }

    /// Scoped update for run-progress ticks (plans/013): skips the goal-editor
    /// sync/focus handling (only relevant on tab entry) and appends only new log
    /// lines instead of replacing the whole live-log string every tick.
    func reloadProgress() {
        updateRunInfo()
        updateActivity()
        logView.appendLines(model.liveLog)
        updateControls()
        updateApprovalBox()
        rebuildHandoffIfChanged(model.lastInspection ?? model.pendingApproval?.inspection)
        updatePulse(model.isRunning)
    }

    private func updateRunInfo() {
        let copy = model.runProgressCopy()
        runInfo.stringValue = copy.runInfo
        if model.isRunning {
            runInfo.textColor = Theme.accent
        } else if model.run?.status == .succeeded {
            runInfo.textColor = Theme.accent
        } else if model.run?.status == .failed {
            runInfo.textColor = Theme.danger
        } else if model.run?.status == .awaitingApproval || model.pendingApproval != nil {
            runInfo.textColor = Theme.warning
        } else {
            runInfo.textColor = Theme.muted
        }
    }

    private func updateActivity() {
        let copy = model.runProgressCopy()
        let awaitingApproval = model.run?.status == .awaitingApproval || model.pendingApproval != nil
        let failed = model.run?.status == .failed && !model.isRunning
        let succeeded = model.run?.status == .succeeded && !model.isRunning
        let cancelled = model.run?.status == .cancelled && !model.isRunning
        let wrapWidth = max(activityRow.bounds.width - 28, logView.bounds.width - 8, 240)
        activityLabel.preferredMaxLayoutWidth = wrapWidth

        if model.isRunning {
            activityRow.isHidden = false
            activitySpinner.startAnimation(nil)
            activityLabel.stringValue = copy.activityText
            activityLabel.textColor = Theme.accent
        } else if awaitingApproval {
            activityRow.isHidden = false
            activitySpinner.stopAnimation(nil)
            activityLabel.stringValue = copy.activityText
            activityLabel.textColor = Theme.warning
        } else if failed {
            activityRow.isHidden = false
            activitySpinner.stopAnimation(nil)
            activityLabel.stringValue = failureStripText(using: copy)
            activityLabel.textColor = Theme.danger
        } else if succeeded || cancelled {
            activityRow.isHidden = false
            activitySpinner.stopAnimation(nil)
            activityLabel.stringValue = copy.activityText
            activityLabel.textColor = succeeded ? Theme.accent : Theme.muted
        } else {
            activitySpinner.stopAnimation(nil)
            activityRow.isHidden = true
            activityLabel.stringValue = ""
        }
    }

    /// Failure strip for the Run console: progress headline, error body, Retry/History tip.
    private func failureStripText(using copy: RunProgressCopy) -> String {
        let body = model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = copy.detail
            ?? "Use Retry Step to try again, or open History to inspect what failed"
        if let body, !body.isEmpty {
            return "\(copy.headline)\n\(body)\n\(tip)"
        }
        return "\(copy.headline)\n\(tip)"
    }

    private func updateControls() {
        playButton.isEnabled = !model.isRunning && model.pendingApproval == nil
        cancelButton.isEnabled = model.isRunning
        retryButton.isEnabled = !model.isRunning
            && (model.run?.status == .failed || model.run?.status == .cancelled)
    }

    private func updateApprovalBox() {
        if let pending = model.pendingApproval {
            approvalBox.isHidden = false
            let fromRole = displayRole(for: pending.inspection.fromNode)
            let toRole = displayRole(for: pending.inspection.toNode)
            var text = "Approve what \(fromRole) passes to \(toRole)\n\(pending.inspection.passed.summary)"
            if let reason = pending.inspection.nextHopReason {
                text += "\nReason: \(reason)"
            }
            approvalLabel.stringValue = text
            if !FirstRunCoach.hasSeenApprovalTip {
                FirstRunCoach.hasSeenApprovalTip = true
                showApprovalCoachForCurrentPause = true
            }
            if showApprovalCoachForCurrentPause {
                approvalCoachLabel.stringValue = FirstRunCoach.approvalTip(
                    fromRole: fromRole,
                    toRole: toRole
                )
                approvalCoachLabel.isHidden = false
            } else {
                approvalCoachLabel.stringValue = ""
                approvalCoachLabel.isHidden = true
            }
            approveButton.isEnabled = !model.isRunning
            rejectButton.isEnabled = !model.isRunning
        } else {
            approvalBox.isHidden = true
            showApprovalCoachForCurrentPause = false
            approvalCoachLabel.stringValue = ""
            approvalCoachLabel.isHidden = true
        }
    }

    private func displayRole(for nodeId: String) -> String {
        model.project?.org.node(id: nodeId)?.role ?? nodeId
    }

    private func handoffSignature(_ inspection: HandoffInspection?) -> String? {
        guard let inspection else { return nil }
        return [
            inspection.edgeId,
            inspection.fromNode,
            inspection.toNode,
            inspection.passed.summary,
            inspection.nextHopReason ?? ""
        ].joined(separator: "\u{1}")
    }

    private func rebuildHandoffIfChanged(_ inspection: HandoffInspection?) {
        if inspection == nil {
            showHistoryCoachForCurrentHandoff = false
        } else if !FirstRunCoach.hasSeenHistoryTip {
            FirstRunCoach.hasSeenHistoryTip = true
            showHistoryCoachForCurrentHandoff = true
        }
        let signature = (handoffSignature(inspection) ?? "nil")
            + "\u{1}\(showHistoryCoachForCurrentHandoff)"
        guard signature != renderedCoachSignature else { return }
        renderedCoachSignature = signature
        renderedHandoffSignature = handoffSignature(inspection)
        rebuildHandoff(inspection)
    }

    private func rebuildHandoff(_ inspection: HandoffInspection?) {
        handoffStack.arrangedSubviews.forEach {
            handoffStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let inspection else {
            handoffStack.addArrangedSubview(AppKitText.label(
                "Choose Play to see what Planner passes to Implementer, then onward to Reviewer.",
                style: .muted
            ))
            return
        }
        if showHistoryCoachForCurrentHandoff {
            handoffStack.addArrangedSubview(makeHistoryCoachRow())
        }
        handoffStack.addArrangedSubview(kv("Connection", inspection.edgeId))
        handoffStack.addArrangedSubview(kv("From step", displayRole(for: inspection.fromNode)))
        handoffStack.addArrangedSubview(kv("To step", displayRole(for: inspection.toNode)))
        handoffStack.addArrangedSubview(kv("Approval", inspection.requiresApproval ? "required" : "auto"))
        if let reason = inspection.nextHopReason {
            handoffStack.addArrangedSubview(kv("Next hop reason", reason))
        }
        handoffStack.addArrangedSubview(AppKitText.label("Included", style: .section))
        handoffStack.addArrangedSubview(kv("Summary", inspection.passed.summary))
        for path in inspection.passed.artifacts {
            let label = AppKitText.label(path, style: .mono)
            handoffStack.addArrangedSubview(label)
        }
        for check in inspection.passed.checks {
            handoffStack.addArrangedSubview(AppKitText.label("\(check.passed ? "✓" : "✗") \(check.name)", style: .caption))
        }
        handoffStack.addArrangedSubview(AppKitText.label("Not included", style: .section))
        if inspection.withheld.isEmpty {
            handoffStack.addArrangedSubview(AppKitText.label("Everything needed was included.", style: .muted))
        } else {
            for field in inspection.withheld {
                handoffStack.addArrangedSubview(AppKitText.label(field.rawValue, style: .caption))
            }
        }
    }

    private func makeHistoryCoachRow() -> NSView {
        let tip = AppKitText.label(FirstRunCoach.historyTip, style: .caption)
        tip.textColor = Theme.muted
        tip.maximumNumberOfLines = 3
        tip.lineBreakMode = .byWordWrapping
        let open = PrimaryButton(
            title: "Open History",
            style: .secondary,
            target: self,
            action: #selector(openHistoryCoach)
        )
        open.controlSize = .small
        let row = NSStackView(views: [tip, open])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        tip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func openHistoryCoach() {
        FirstRunCoach.hasSeenHistoryTip = true
        showHistoryCoachForCurrentHandoff = false
        renderedCoachSignature = nil
        model.openHistoryForCurrentRun()
    }

    private func kv(_ key: String, _ value: String) -> NSView {
        let k = AppKitText.label(key, style: .caption)
        k.textColor = Theme.muted
        let v = AppKitText.label(value, style: .body)
        let stack = NSStackView(views: [k, v])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func updatePulse(_ running: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        if running {
            if pulseLayer == nil {
                let layer = CALayer()
                layer.backgroundColor = Theme.accent.cgColor
                layer.frame = CGRect(x: 0, y: 0, width: 4, height: 44)
                view.layer?.addSublayer(layer)
                pulseLayer = layer
            }
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let layer = self.pulseLayer else { return }
                    let t = CACurrentMediaTime()
                    let alpha = 0.35 + 0.45 * abs(sin(t * 4))
                    layer.backgroundColor = Theme.accent.withAlphaComponent(alpha).cgColor
                }
            }
        } else {
            pulseLayer?.removeFromSuperlayer()
            pulseLayer = nil
        }
    }

    private func wrap(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let preferred = scroll.heightAnchor.constraint(equalToConstant: height)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return scroll
    }

    @objc private func startRun() { model.play() }
    @objc private func cancelRun() { model.cancelRun() }
    @objc private func retryRun() { model.retryRun() }
    @objc private func gitignore() { model.ensureArtifactsGitignore() }
    @objc private func approve() { model.approve() }
    @objc private func reject() { model.rejectApproval() }
}

extension RunConsoleController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === goalView else { return }
        model.goalDraft = view.string
    }
}
