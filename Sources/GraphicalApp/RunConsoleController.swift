import AppKit
import GraphicalDomain

@MainActor
final class RunConsoleController: NSObject {
    var model: AppModel!
    let view = NSView()

    private let goalView = NSTextView()
    private let logView = MonoLogView()
    private let runInfo = AppKitText.label("", style: .body)
    private let playButton: PrimaryButton
    private let cancelButton: PrimaryButton
    private let approvalBox = NSView()
    private let approvalLabel = AppKitText.label("", style: .body)
    private let handoffStack = NSStackView()
    private var pulseLayer: CALayer?
    private var pulseTimer: Timer?

    override init() {
        playButton = PrimaryButton(title: "Play", style: .primary, target: nil, action: nil)
        cancelButton = PrimaryButton(title: "Cancel", style: .secondary, target: nil, action: nil)
        super.init()
        playButton.target = self
        playButton.action = #selector(startRun)
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.imagePosition = .imageLeading
        cancelButton.target = self
        cancelButton.action = #selector(cancelRun)
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
            "Plays the org from the entry node using Agents + models on each node.",
            style: .muted
        )
        subtitle.maximumNumberOfLines = 2
        let goalScroll = wrap(goalView, height: 100)
        goalView.isRichText = false
        goalView.font = Theme.bodyFont()
        goalView.delegate = self

        let retry = PrimaryButton(title: "Retry Node", style: .secondary, target: self, action: #selector(retryRun))
        let gitignore = PrimaryButton(title: "Artifacts .gitignore", style: .ghost, target: self, action: #selector(gitignore))
        let buttons = NSStackView(views: [playButton, cancelButton, retry, gitignore])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        approvalBox.wantsLayer = true
        approvalBox.layer?.backgroundColor = Theme.warningSoft.cgColor
        approvalBox.layer?.cornerRadius = Theme.controlRadius
        approvalBox.translatesAutoresizingMaskIntoConstraints = false
        approvalLabel.translatesAutoresizingMaskIntoConstraints = false
        let approve = PrimaryButton(title: "Approve", style: .primary, target: self, action: #selector(approve))
        let reject = PrimaryButton(title: "Reject", style: .danger, target: self, action: #selector(reject))
        let approvalButtons = NSStackView(views: [approve, reject])
        approvalButtons.orientation = .horizontal
        approvalButtons.spacing = 8
        approvalButtons.translatesAutoresizingMaskIntoConstraints = false
        approvalBox.addSubview(approvalLabel)
        approvalBox.addSubview(approvalButtons)
        NSLayoutConstraint.activate([
            approvalLabel.leadingAnchor.constraint(equalTo: approvalBox.leadingAnchor, constant: 12),
            approvalLabel.trailingAnchor.constraint(equalTo: approvalBox.trailingAnchor, constant: -12),
            approvalLabel.topAnchor.constraint(equalTo: approvalBox.topAnchor, constant: 12),
            approvalButtons.leadingAnchor.constraint(equalTo: approvalLabel.leadingAnchor),
            approvalButtons.topAnchor.constraint(equalTo: approvalLabel.bottomAnchor, constant: 10),
            approvalButtons.bottomAnchor.constraint(equalTo: approvalBox.bottomAnchor, constant: -12)
        ])

        let goalLabel = AppKitText.label("Goal", style: .caption)
        goalLabel.textColor = Theme.muted
        let logTitle = AppKitText.label("Live Log", style: .section)
        let leftStack = NSStackView(views: [
            title, subtitle, goalLabel, goalScroll, buttons, runInfo, approvalBox, logTitle, logView
        ])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        left.addSubview(leftStack)

        let handoffTitle = AppKitText.label("Handoff Inspector", style: .title)
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
        right.addSubview(rightStack)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(left)
        view.addSubview(border)
        view.addSubview(right)

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            left.topAnchor.constraint(equalTo: view.topAnchor),
            left.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            left.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.58),

            border.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            border.topAnchor.constraint(equalTo: view.topAnchor),
            border.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            right.leadingAnchor.constraint(equalTo: border.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            right.topAnchor.constraint(equalTo: view.topAnchor),
            right.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            leftStack.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            leftStack.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            leftStack.topAnchor.constraint(equalTo: left.topAnchor),
            leftStack.bottomAnchor.constraint(equalTo: left.bottomAnchor),

            rightStack.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            rightStack.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            rightStack.topAnchor.constraint(equalTo: right.topAnchor),

            goalScroll.widthAnchor.constraint(equalTo: leftStack.widthAnchor, constant: -32),
            logView.widthAnchor.constraint(equalTo: leftStack.widthAnchor, constant: -32),
            logView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            approvalBox.widthAnchor.constraint(equalTo: leftStack.widthAnchor, constant: -32),
            handoffStack.widthAnchor.constraint(equalTo: rightStack.widthAnchor, constant: -32)
        ])
    }

    func reload() {
        if goalView.window?.firstResponder !== goalView,
           goalView.string != model.goalDraft {
            goalView.string = model.goalDraft
        }
        if model.focusRunGoal {
            model.consumeFocusRunGoal()
            view.window?.makeFirstResponder(goalView)
        }
        if let run = model.run {
            var info = "ID \(run.id.prefix(8)) · \(run.status.rawValue)"
            if let nodeId = run.activeNodeId {
                let role = model.project?.org.node(id: nodeId)?.role ?? nodeId
                info += " · \(role)"
            }
            if let phase = model.runPhase {
                info += " · \(phase)"
            }
            if let iteration = model.runIteration,
               let nodeId = run.activeNodeId,
               let max = model.project?.org.node(id: nodeId)?.maxIterations {
                info += " · iteration \(iteration)/\(max)"
            }
            runInfo.stringValue = info
            runInfo.textColor = model.isRunning ? Theme.accent : Theme.text
        } else {
            runInfo.stringValue = "No active run"
            runInfo.textColor = Theme.muted
        }
        logView.setLines(model.liveLog)

        playButton.isEnabled = !model.isRunning && model.pendingApproval == nil
        cancelButton.isEnabled = model.isRunning

        if let pending = model.pendingApproval {
            approvalBox.isHidden = false
            var text = "Approval: \(pending.inspection.fromNode) → \(pending.inspection.toNode)\n\(pending.inspection.passed.summary)"
            if let reason = pending.inspection.nextHopReason {
                text += "\nReason: \(reason)"
            }
            approvalLabel.stringValue = text
        } else {
            approvalBox.isHidden = true
        }

        rebuildHandoff(model.lastInspection ?? model.pendingApproval?.inspection)
        updatePulse(model.isRunning)
    }

    private func rebuildHandoff(_ inspection: HandoffInspection?) {
        handoffStack.arrangedSubviews.forEach {
            handoffStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let inspection else {
            handoffStack.addArrangedSubview(AppKitText.label("No handoff yet. Play a run to inspect edge payloads.", style: .muted))
            return
        }
        handoffStack.addArrangedSubview(kv("Edge", inspection.edgeId))
        handoffStack.addArrangedSubview(kv("From", inspection.fromNode))
        handoffStack.addArrangedSubview(kv("To", inspection.toNode))
        handoffStack.addArrangedSubview(kv("Approval", inspection.requiresApproval ? "required" : "auto"))
        if let reason = inspection.nextHopReason {
            handoffStack.addArrangedSubview(kv("Next hop reason", reason))
        }
        handoffStack.addArrangedSubview(AppKitText.label("Passed", style: .section))
        handoffStack.addArrangedSubview(kv("Summary", inspection.passed.summary))
        for path in inspection.passed.artifacts {
            let label = AppKitText.label(path, style: .mono)
            handoffStack.addArrangedSubview(label)
        }
        for check in inspection.passed.checks {
            handoffStack.addArrangedSubview(AppKitText.label("\(check.passed ? "✓" : "✗") \(check.name)", style: .caption))
        }
        handoffStack.addArrangedSubview(AppKitText.label("Withheld", style: .section))
        if inspection.withheld.isEmpty {
            handoffStack.addArrangedSubview(AppKitText.label("Nothing withheld", style: .muted))
        } else {
            for field in inspection.withheld {
                handoffStack.addArrangedSubview(AppKitText.label(field.rawValue, style: .caption))
            }
        }
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
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
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
