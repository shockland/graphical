import AppKit
import GraphicalCLI

@MainActor
protocol SetupAssistantControllerDelegate: AnyObject {
    func setupAssistant(
        _ controller: SetupAssistantController,
        finishWithGoal goal: String,
        presetID: String
    ) -> Bool
    func setupAssistant(
        _ controller: SetupAssistantController,
        finishWithPresetID presetID: String
    ) -> Bool
    func setupAssistantDidDismiss(_ controller: SetupAssistantController)
}

@MainActor
final class SetupAssistantController: NSWindowController, NSTextViewDelegate {
    weak var delegate: SetupAssistantControllerDelegate?

    private var session: SetupSession
    private let probeService: AgentProbeService
    private var probeTask: Task<Void, Never>?

    private let titleLabel = AppKitText.label("", style: .title)
    private let stepLabel = AppKitText.label("", style: .muted)
    private let pageHost = NSView()
    private let goalTextView = NSTextView()
    private let presetPicker = AgentPresetPickerView()
    private let backButton = PrimaryButton(title: "Back", style: .secondary, target: nil, action: nil)
    private let useAnywayButton = PrimaryButton(title: "Use anyway", style: .secondary, target: nil, action: nil)
    private let primaryButton = PrimaryButton(title: "Continue", style: .primary, target: nil, action: nil)
    private let cancelButton = PrimaryButton(title: "Cancel", style: .ghost, target: nil, action: nil)
    private let errorLabel = AppKitText.label("", style: .caption)

    init(
        session: SetupSession = SetupSession(),
        probeService: AgentProbeService = AgentProbeService()
    ) {
        self.session = session
        self.probeService = probeService
        let preferred = NSSize(width: 640, height: 480)
        let visible = NSScreen.main?.visibleFrame.size ?? preferred
        let sheetSize = NSSize(
            width: min(preferred.width, max(360, visible.width - 48)),
            height: min(preferred.height, max(320, visible.height - 48))
        )
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: sheetSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        switch session.mode {
        case .firstRun:
            sheet.title = "Set Up New Project"
        case .codingToolOnly:
            sheet.title = "Set Up Coding Tool"
        }
        sheet.backgroundColor = Theme.background
        sheet.isReleasedWhenClosed = false
        sheet.contentMinSize = NSSize(width: 360, height: 320)
        sheet.contentMaxSize = sheetSize
        sheet.maxSize = sheetSize
        super.init(window: sheet)
        buildUI()
        if let presetID = session.selectedPresetID {
            presetPicker.setSelectedPresetID(presetID)
        }
        showCurrentPage()
        probeKnownTools()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        probeTask?.cancel()
    }

    func focusInitialControl() {
        switch session.mode {
        case .firstRun where session.currentStep == .goal:
            window?.makeFirstResponder(goalTextView)
        default:
            window?.makeFirstResponder(nil)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.cgColor

        switch session.mode {
        case .firstRun:
            titleLabel.stringValue = "Set up your first run"
        case .codingToolOnly:
            titleLabel.stringValue = "Set up your coding tool"
        }

        let header = NSStackView(views: [titleLabel, NSView(), stepLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        pageHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        pageHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.setAccessibilityLabel("Go to previous setup step")
        useAnywayButton.target = self
        useAnywayButton.action = #selector(useAnywayTapped)
        useAnywayButton.setAccessibilityLabel("Use selected coding tool even if not detected")
        useAnywayButton.isHidden = true
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        errorLabel.textColor = Theme.danger
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2

        let actions = NSStackView(views: [
            cancelButton, NSView(), backButton, useAnywayButton, primaryButton
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let footer = NSStackView(views: [errorLabel, actions])
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = 8

        let root = NSStackView(views: [header, pageHost, footer])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        root.pinEdges(
            to: content,
            insets: NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        )

        configureGoalEditor()
        presetPicker.onSelectPreset = { [weak self] presetID in
            self?.session.selectedPresetID = presetID
            self?.clearInlineError()
            self?.updateButtons()
        }
        presetPicker.onRefresh = { [weak self] in
            self?.probeKnownTools()
        }
        presetPicker.onSelectionOrStatusChange = { [weak self] in
            self?.updateButtons()
        }
    }

    private func configureGoalEditor() {
        goalTextView.delegate = self
        goalTextView.string = session.goal
        goalTextView.isRichText = false
        goalTextView.isAutomaticQuoteSubstitutionEnabled = false
        goalTextView.font = Theme.bodyFont(ofSize: 14)
        goalTextView.textColor = Theme.text
        goalTextView.backgroundColor = Theme.surface
        goalTextView.textContainerInset = NSSize(width: 10, height: 10)
        goalTextView.setAccessibilityLabel("Goal for this work")
        goalTextView.setAccessibilityHelp(
            "Describe what should be true when the work is finished."
        )
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === goalTextView else { return }
        session.goal = goalTextView.string
        clearInlineError()
        updateButtons()
    }

    private func showCurrentPage() {
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        switch session.currentStep {
        case .goal:
            page = makeGoalPage()
        case .codingTool:
            page = makeCodingToolPage()
        }
        pageHost.addSubview(page)
        page.pinEdges(to: pageHost)

        switch session.mode {
        case .firstRun:
            stepLabel.isHidden = false
            stepLabel.stringValue =
                "Step \(session.currentStep.rawValue + 1) of \(SetupSession.Step.allCases.count)"
        case .codingToolOnly:
            stepLabel.isHidden = true
            stepLabel.stringValue = ""
        }

        clearInlineError()
        updateButtons()
        if session.mode == .firstRun, session.currentStep == .goal {
            window?.makeFirstResponder(goalTextView)
        }
    }

    private func makeGoalPage() -> NSView {
        let heading = AppKitText.label(
            "What should be true when this work is finished?",
            style: .title
        )
        let detail = AppKitText.label(
            "Describe the result you want. Planner, Implementer, and Reviewer will share this goal.",
            style: .muted
        )
        detail.maximumNumberOfLines = 2

        let scroll = ThemedScrollView()
        scroll.documentView = goalTextView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        let examples = AppKitText.label(
            "Examples for inspiration only: “The import completes without duplicate records.”  “Customers can export invoices as PDF.”",
            style: .caption
        )
        examples.textColor = Theme.muted
        examples.maximumNumberOfLines = 3
        examples.lineBreakMode = .byWordWrapping

        return pageStack([heading, detail, scroll, examples])
    }

    private func makeCodingToolPage() -> NSView {
        let detail = AppKitText.label(
            "Pick the coding tool for Planner → Implementer → Reviewer. Demo works without installing anything.",
            style: .muted
        )
        detail.maximumNumberOfLines = 3
        return pageStack([detail, presetPicker])
    }

    private func pageStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func updateButtons() {
        backButton.isHidden = session.mode == .codingToolOnly
        backButton.isEnabled = session.canGoBack

        let onToolStep = session.currentStep == .codingTool
        let needsUseAnyway = onToolStep && presetPicker.selectedPresetNeedsUseAnyway()
        useAnywayButton.isHidden = !needsUseAnyway
        useAnywayButton.isEnabled = session.canContinue && needsUseAnyway

        switch session.currentStep {
        case .goal:
            primaryButton.title = "Continue"
            primaryButton.isEnabled = session.canContinue
            primaryButton.action = #selector(primaryTapped)
        case .codingTool:
            if presetPicker.selectedPresetIsChecking() {
                primaryButton.title = "Checking…"
                primaryButton.isEnabled = false
                primaryButton.action = #selector(primaryTapped)
            } else if needsUseAnyway {
                primaryButton.title = "Check again"
                primaryButton.isEnabled = true
                primaryButton.action = #selector(checkAgainTapped)
            } else {
                switch session.mode {
                case .firstRun:
                    primaryButton.title = "Open workflow"
                case .codingToolOnly:
                    let name = AgentPresetCatalog.preset(id: session.selectedPresetID ?? "")?
                        .displayName ?? "tool"
                    primaryButton.title = "Use \(name)"
                }
                primaryButton.isEnabled = session.canContinue
                    && presetPicker.isPresetSelectable(session.selectedPresetID)
                    && presetPicker.isSelectedPresetVerifiedInstalled()
                primaryButton.action = #selector(primaryTapped)
            }
        }
        primaryButton.setAccessibilityLabel(primaryButton.title)
    }

    private func probeKnownTools() {
        let previousTask = probeTask
        previousTask?.cancel()
        for preset in AgentPresetCatalog.all where preset.id != AgentPresetCatalog.demo.id {
            presetPicker.setStatus(.checking, for: preset.id)
        }
        updateButtons()

        let ids = AgentPresetCatalog.all
            .filter { $0.id != AgentPresetCatalog.demo.id }
            .map(\.id)
        let service = probeService
        probeTask = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            for presetID in ids {
                guard !Task.isCancelled else { return }
                let detection: AgentPresetPickerView.DetectionStatus
                do {
                    switch try await service.probe(presetID: presetID) {
                    case .installed(let version):
                        detection = .installed(version: version)
                    case .missing:
                        detection = .missing
                    case .failed:
                        detection = .failed
                    }
                } catch {
                    detection = .failed
                }
                guard !Task.isCancelled, let self else { return }
                self.presetPicker.setStatus(detection, for: presetID)
                self.updateButtons()
            }
        }
    }

    @objc private func backTapped() {
        guard session.back() else { return }
        showCurrentPage()
    }

    @objc private func checkAgainTapped() {
        clearInlineError()
        probeKnownTools()
    }

    @objc private func useAnywayTapped() {
        guard session.currentStep == .codingTool,
              let presetID = session.selectedPresetID else {
            return
        }
        clearInlineError()
        switch session.mode {
        case .codingToolOnly:
            finishWithPreset(presetID)
        case .firstRun:
            finishFirstRun(presetID: presetID)
        }
    }

    @objc private func primaryTapped() {
        switch session.mode {
        case .codingToolOnly:
            guard let presetID = session.selectedPresetID,
                  presetPicker.isSelectedPresetVerifiedInstalled() else {
                return
            }
            finishWithPreset(presetID)
        case .firstRun:
            if session.currentStep == .codingTool {
                guard let presetID = session.selectedPresetID,
                      presetPicker.isSelectedPresetVerifiedInstalled() else {
                    return
                }
                finishFirstRun(presetID: presetID)
                return
            }
            guard session.advance() else { return }
            showCurrentPage()
        }
    }

    private func finishFirstRun(presetID: String) {
        if delegate?.setupAssistant(
            self,
            finishWithGoal: session.goal,
            presetID: presetID
        ) == true {
            dismiss()
        } else {
            errorLabel.stringValue =
                "The project could not be saved. Review the project status and try again."
            errorLabel.isHidden = false
        }
    }

    private func finishWithPreset(_ presetID: String) {
        if delegate?.setupAssistant(self, finishWithPresetID: presetID) == true {
            dismiss()
        } else {
            errorLabel.stringValue =
                "The coding tool could not be applied. Review the project status and try again."
            errorLabel.isHidden = false
        }
    }

    @objc private func cancelTapped() {
        dismiss()
    }

    private func clearInlineError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    private func dismiss() {
        probeTask?.cancel()
        if let sheet = window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            close()
        }
        delegate?.setupAssistantDidDismiss(self)
    }
}
