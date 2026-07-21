import AppKit
import GraphicalCLI
import GraphicalDomain

@MainActor
final class MainWindowController: NSWindowController, AppModelDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let rail = NavRailView()
    private let topBar = TopBarView()
    private let statusBar = StatusBarView()
    private let contentHost = NSView()
    private let validationBanner = ValidationBannerView()
    private let emptyState = EmptyStateView()

    private let orgWorkspace = OrgWorkspaceController()
    private let runWorkspace = RunConsoleController()
    private let traceWorkspace = TraceController()
    private let runnersWorkspace = RunnersController()

    /// Plain container views — avoid NSStackView here. Horizontal stacks were
    /// sizing the main column to its fitting width and parking the workflow
    /// chrome in a trailing strip with a large void beside the rail.
    private let rootRow = NSView()
    private let mainColumn = NSView()

    private var validationHeight: NSLayoutConstraint?
    private var shownKey: String?
    private var cancelMenuItem: NSMenuItem?
    private var tabMenuItems: [NSMenuItem] = []
    private var setupAssistant: SetupAssistantController?
    private var setupPresentationScheduled = false
    private var codingToolSetupPresentationScheduled = false
    private var screenObserver: NSObjectProtocol?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Graphical"
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = false
        // Soft floor; `fitWindowToVisibleScreen` clamps both min and initial
        // frame to the actual visible screen so small laptops / split views
        // never get a window larger than the display.
        window.minSize = NSSize(width: 560, height: 400)
        self.init(window: window)
        window.delegate = self
        Self.fitWindowToVisibleScreen(window, resetToDefaultSize: true)
        model.delegate = self
        buildUI()
        reload()
        // Auto Layout can grow the window to content's fitting size after the
        // chrome is installed — clamp again so we stay on-screen.
        Self.fitWindowToVisibleScreen(window, resetToDefaultSize: true)
        observeScreenChanges()
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            Self.fitWindowToVisibleScreen(window, resetToDefaultSize: false)
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let window = self?.window else { return }
                Self.fitWindowToVisibleScreen(window, resetToDefaultSize: false)
            }
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let maxOuter = Self.maxOuterSize(for: sender)
        return NSSize(
            width: min(frameSize.width, maxOuter.width),
            height: min(frameSize.height, maxOuter.height)
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        Self.fitWindowToVisibleScreen(window, resetToDefaultSize: false)
    }

    private static func maxOuterSize(for window: NSWindow) -> NSSize {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 16
        return NSSize(
            width: max(320, visible.width - margin * 2),
            height: max(240, visible.height - margin * 2)
        )
    }

    /// Keeps the window inside the screen's visible frame (menu bar / dock /
    /// Stage Manager). Sets hard max sizes so Auto Layout cannot grow past the
    /// display. When `resetToDefaultSize` is false, only shrinks if oversized
    /// and refreshes min/max — preserves a user-chosen smaller size.
    private static func fitWindowToVisibleScreen(_ window: NSWindow, resetToDefaultSize: Bool) {
        guard let screen = window.screen ?? NSScreen.main else {
            window.center()
            return
        }

        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let maxOuter = maxOuterSize(for: window)

        // Hard cap: content fitting size must not push the window off-screen.
        window.maxSize = maxOuter
        window.contentMaxSize = NSSize(
            width: max(280, maxOuter.width - 20),
            height: max(180, maxOuter.height - 40)
        )

        var size: NSSize
        if resetToDefaultSize {
            // Comfortable default — not nearly full-bleed.
            size = NSSize(
                width: min(1024, maxOuter.width * 0.82),
                height: min(700, maxOuter.height * 0.85)
            )
        } else {
            size = window.frame.size
        }
        size.width = max(320, min(size.width, maxOuter.width))
        size.height = max(240, min(size.height, maxOuter.height))

        // Min size must be ≤ both the launch size and the visible area, or Auto
        // Layout will fight the window chrome and content will overflow.
        let minWidth = min(560, maxOuter.width, size.width)
        let minHeight = min(400, maxOuter.height, size.height)
        window.minSize = NSSize(width: minWidth, height: minHeight)
        window.contentMinSize = NSSize(
            width: max(280, minWidth - 20),
            height: max(180, minHeight - 40)
        )

        var origin = window.frame.origin
        if resetToDefaultSize {
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }
        origin.x = max(visible.minX + margin, min(origin.x, visible.maxX - size.width - margin))
        origin.y = max(visible.minY + margin, min(origin.y, visible.maxY - size.height - margin))

        var frame = NSRect(origin: origin, size: size)
        frame = window.constrainFrameRect(frame, to: screen)
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        frame.size.width = min(frame.width, maxOuter.width)
        frame.size.height = min(frame.height, maxOuter.height)

        if resetToDefaultSize
            || abs(frame.width - window.frame.width) > 0.5
            || abs(frame.height - window.frame.height) > 0.5
            || abs(frame.minX - window.frame.minX) > 0.5
            || abs(frame.minY - window.frame.minY) > 0.5 {
            window.setFrame(frame, display: true)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.cgColor
        content.clipsToBounds = true

        rail.delegate = self
        topBar.delegate = self
        emptyState.delegate = self
        orgWorkspace.model = model
        runWorkspace.model = model
        traceWorkspace.model = model
        runnersWorkspace.model = model

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        contentHost.clipsToBounds = true
        contentHost.layer?.backgroundColor = Theme.background.cgColor
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        validationHeight = validationBanner.heightAnchor.constraint(equalToConstant: 0)
        validationHeight?.isActive = true
        validationBanner.isHidden = true
        validationBanner.clipsToBounds = true
        validationBanner.delegate = self

        for view in [rootRow, mainColumn, topBar, validationBanner, contentHost, statusBar, rail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        mainColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mainColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rail.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Prefer compressing chrome over growing the window past the screen.
        rail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rootRow.addSubview(rail)
        rootRow.addSubview(mainColumn)
        mainColumn.addSubview(topBar)
        mainColumn.addSubview(validationBanner)
        mainColumn.addSubview(contentHost)
        mainColumn.addSubview(statusBar)
        content.addSubview(rootRow)

        let railWidth = rail.widthAnchor.constraint(equalToConstant: Theme.railWidth)
        railWidth.priority = .defaultHigh
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            rootRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootRow.topAnchor.constraint(equalTo: content.topAnchor),
            rootRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            rail.leadingAnchor.constraint(equalTo: rootRow.leadingAnchor),
            rail.topAnchor.constraint(equalTo: rootRow.topAnchor),
            rail.bottomAnchor.constraint(equalTo: rootRow.bottomAnchor),
            railWidth,
            rail.widthAnchor.constraint(lessThanOrEqualTo: rootRow.widthAnchor, multiplier: 0.32),
            rail.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            mainColumn.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            mainColumn.trailingAnchor.constraint(equalTo: rootRow.trailingAnchor),
            mainColumn.topAnchor.constraint(equalTo: rootRow.topAnchor),
            mainColumn.bottomAnchor.constraint(equalTo: rootRow.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: mainColumn.topAnchor),

            validationBanner.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            validationBanner.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            validationBanner.topAnchor.constraint(equalTo: topBar.bottomAnchor),

            contentHost.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: validationBanner.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor)
        ])

        installMenus()
    }

    private func installMenus() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Graphical", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Project Folder…", action: #selector(menuOpen), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Create Project in Folder…", action: #selector(menuCreate), keyEquivalent: "n")
        let closeItem = fileMenu.addItem(
            withTitle: "Close Project",
            action: #selector(menuClose),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Save", action: #selector(menuSave), keyEquivalent: "s")
        fileItem.submenu = fileMenu

        let runItem = NSMenuItem()
        main.addItem(runItem)
        let runMenu = NSMenu(title: "Run")
        runMenu.addItem(withTitle: "Run Workflow", action: #selector(menuPlay), keyEquivalent: "r")
        cancelMenuItem = runMenu.addItem(withTitle: "Cancel", action: #selector(menuCancel), keyEquivalent: ".")
        runItem.submenu = runMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        for (index, tab) in AppModel.AppTab.allCases.enumerated() {
            let item = viewMenu.addItem(
                withTitle: tab.rawValue,
                action: #selector(menuSelectTab(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.tag = index
            tabMenuItems.append(item)
        }
        viewItem.submenu = viewMenu

        // Edit menu is required for Cmd+C/V/X/A to reach NSTextField / NSTextView.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }

    @objc private func menuOpen() { model.openProjectPanel() }
    @objc private func menuCreate() { model.createProjectPanel() }
    @objc private func menuClose() { model.closeProject() }
    @objc private func menuSave() { model.saveProject() }
    @objc private func menuPlay() { model.play() }
    @objc private func menuCancel() { model.cancelRun() }
    @objc private func menuSelectTab(_ sender: NSMenuItem) {
        guard model.project != nil else { return }
        let tabs = AppModel.AppTab.allCases
        guard sender.tag >= 0, sender.tag < tabs.count else { return }
        model.selectedTab = tabs[sender.tag]
    }

    private func updateMenuState() {
        let hasProject = model.project != nil
        for item in tabMenuItems {
            item.isEnabled = hasProject
        }
        cancelMenuItem?.isEnabled = hasProject
            && (model.isRunning || model.pendingApproval != nil)
    }

    func appModelDidChange(_ model: AppModel) {
        reload()
    }

    func appModelDirtyStateDidChange(_ model: AppModel) {
        topBar.reload(from: model)
    }

    /// Scoped path for run-progress ticks (plans/013): update only run-status-adjacent
    /// chrome and, if the Run tab is showing, the run console's own scoped reload —
    /// never rebuild org/trace/runners or tear down the nav rail's recent-runs list.
    func appModelRunProgressDidChange(_ model: AppModel) {
        topBar.reload(from: model)
        rail.updateRunningIndicator(isRunning: model.isRunning)
        statusBar.update(
            error: model.errorMessage,
            status: model.statusMessage,
            workspaceHint: orgWorkspace.statusHint(for: model),
            isRunning: model.isRunning,
            hasProject: model.project != nil
        )
        if model.project != nil, model.selectedTab == .run {
            runWorkspace.reloadProgress()
        }
        if model.project != nil, model.selectedTab == .trace {
            traceWorkspace.reloadProgress()
        }
        if model.project != nil {
            orgWorkspace.reloadRunHighlight()
        }
        updateMenuState()
    }

    private func reload() {
        rail.reload(from: model)
        topBar.reload(from: model)
        statusBar.update(
            error: model.errorMessage,
            status: model.statusMessage,
            workspaceHint: orgWorkspace.statusHint(for: model),
            isRunning: model.isRunning,
            hasProject: model.project != nil
        )
        updateValidation()
        updateMenuState()
        if model.project != nil {
            orgWorkspace.reloadRunHighlight()
        }
        showCurrentContent()
        scheduleSetupPresentationIfNeeded()
        scheduleCodingToolSetupPresentationIfNeeded()
    }

    private func scheduleSetupPresentationIfNeeded() {
        guard setupAssistant == nil,
              !setupPresentationScheduled,
              let requestedRoot = model.consumeSetupPresentationRequest() else {
            return
        }
        setupPresentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupPresentationScheduled = false
            guard self.setupAssistant == nil,
                  self.model.project?.root.standardizedFileURL == requestedRoot,
                  let parentWindow = self.window,
                  parentWindow.attachedSheet == nil else {
                return
            }

            let controller = SetupAssistantController(
                session: SetupSession(
                    mode: .firstRun,
                    goal: self.model.goalDraft,
                    meshWidth: self.model.project?.config.meshWidth ?? 3,
                    parallelFanOut: self.model.project?.config.parallelFanOut ?? true,
                    selectedPresetID: self.model.inferredCodingToolPresetID() ?? "demo"
                )
            )
            controller.delegate = self
            self.setupAssistant = controller
            guard let sheet = controller.window else {
                self.setupAssistant = nil
                return
            }
            parentWindow.beginSheet(sheet)
            controller.focusInitialControl()
        }
    }

    private func scheduleCodingToolSetupPresentationIfNeeded() {
        guard setupAssistant == nil,
              !codingToolSetupPresentationScheduled,
              model.consumeCodingToolSetupRequest(),
              model.project != nil else {
            return
        }
        codingToolSetupPresentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.codingToolSetupPresentationScheduled = false
            guard self.setupAssistant == nil,
                  self.model.project != nil,
                  let parentWindow = self.window,
                  parentWindow.attachedSheet == nil else {
                return
            }

            let controller = SetupAssistantController(
                session: SetupSession(
                    mode: .codingToolOnly,
                    goal: self.model.goalDraft,
                    selectedPresetID: self.model.inferredCodingToolPresetID() ?? "demo"
                )
            )
            controller.delegate = self
            self.setupAssistant = controller
            guard let sheet = controller.window else {
                self.setupAssistant = nil
                return
            }
            parentWindow.beginSheet(sheet)
            controller.focusInitialControl()
        }
    }

    private func updateValidation() {
        let issues = model.validationIssues
        if model.project != nil, !issues.isEmpty {
            validationBanner.isHidden = false
            validationBanner.setIssues(issues)
            validationHeight?.constant = validationBanner.preferredHeight
        } else {
            validationBanner.isHidden = true
            validationHeight?.constant = 0
        }
    }

    private func showCurrentContent() {
        let key: String
        if model.project == nil {
            key = "empty"
        } else {
            key = model.selectedTab.rawValue
        }

        if shownKey != key {
            contentHost.subviews.forEach { $0.removeFromSuperview() }
            let child: NSView
            if model.project == nil {
                child = emptyState
            } else {
                switch model.selectedTab {
                case .org: child = orgWorkspace.view
                case .run: child = runWorkspace.view
                case .trace: child = traceWorkspace.view
                case .runners: child = runnersWorkspace.view
                }
            }
            contentHost.addSubview(child)
            child.pinEdges(to: contentHost)
            shownKey = key
        }

        guard model.project != nil else { return }
        switch model.selectedTab {
        case .org: orgWorkspace.reload()
        case .run: runWorkspace.reload()
        case .trace: traceWorkspace.reload()
        case .runners: runnersWorkspace.reload()
        }
    }
}

extension MainWindowController: ValidationBannerViewDelegate {
    func validationBanner(_ banner: ValidationBannerView, didSelect issue: OrgValidationIssue) {
        model.focusValidationIssue(issue)
    }
}

extension MainWindowController: NavRailViewDelegate {
    func navRail(_ rail: NavRailView, didSelect tab: AppModel.AppTab) {
        model.selectedTab = tab
    }

    func navRailDidSelectOpen(_ rail: NavRailView) {
        model.openProjectPanel()
    }

    func navRailDidSelectCreate(_ rail: NavRailView) {
        model.createProjectPanel()
    }

    func navRailDidSelectClose(_ rail: NavRailView) {
        model.closeProject()
    }

    func navRail(_ rail: NavRailView, didSelectRun runId: String) {
        if let run = model.recentRuns.first(where: { $0.id == runId }) {
            model.loadRun(run)
        }
    }
}

extension MainWindowController: TopBarViewDelegate {
    func topBarDidOpen(_ bar: TopBarView) { model.openProjectPanel() }
    func topBarDidCreate(_ bar: TopBarView) { model.createProjectPanel() }
    func topBarDidClose(_ bar: TopBarView) { model.closeProject() }
    func topBarDidSave(_ bar: TopBarView) { model.saveProject() }
    func topBarDidRun(_ bar: TopBarView) {
        model.play()
    }
}

extension MainWindowController: EmptyStateViewDelegate {
    func emptyStateDidOpen(_ view: EmptyStateView) { model.openProjectPanel() }
    func emptyStateDidCreate(_ view: EmptyStateView) { model.createProjectPanel() }
}

extension MainWindowController: SetupAssistantControllerDelegate {
    func setupAssistant(
        _ controller: SetupAssistantController,
        finishWithGoal goal: String,
        meshWidth: Int,
        parallelFanOut: Bool,
        presetID: String
    ) -> Bool {
        model.completeSetup(
            goal: goal,
            meshWidth: meshWidth,
            parallelFanOut: parallelFanOut,
            presetID: presetID
        )
    }

    func setupAssistant(
        _ controller: SetupAssistantController,
        finishWithPresetID presetID: String
    ) -> Bool {
        model.applyCodingToolPreset(presetID)
    }

    func setupAssistantDidDismiss(_ controller: SetupAssistantController) {
        if setupAssistant === controller {
            setupAssistant = nil
        }
    }
}

final class ValidationBannerView: NSView {
    weak var delegate: ValidationBannerViewDelegate?

    private let summaryButton = NSButton(title: "", target: nil, action: nil)
    private var issues: [OrgValidationIssue] = []
    var preferredHeight: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.warningSoft.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        summaryButton.bezelStyle = .inline
        summaryButton.isBordered = false
        summaryButton.alignment = .left
        summaryButton.target = self
        summaryButton.action = #selector(summaryTapped)
        summaryButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(summaryButton)
        NSLayoutConstraint.activate([
            summaryButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            summaryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            summaryButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setIssues(_ issues: [OrgValidationIssue]) {
        self.issues = issues
        let count = issues.count
        let errors = issues.filter { !$0.isWarning }.count
        let warnings = issues.filter(\.isWarning).count
        let text: String
        if errors == 0, warnings > 0 {
            let noun = warnings == 1 ? "warning" : "warnings"
            text = "\(warnings) workflow \(noun) (advisory) — click to review"
        } else {
            let noun = count == 1 ? "issue" : "issues"
            text = "\(count) workflow \(noun) — click to review"
        }
        summaryButton.contentTintColor = nil
        summaryButton.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: Theme.bodyFont(ofSize: 12, weight: .medium),
                .foregroundColor: Theme.warning
            ]
        )
        preferredHeight = 36
    }

    @objc private func summaryTapped() {
        guard let first = issues.first else { return }
        delegate?.validationBanner(self, didSelect: first)
    }
}

@MainActor
protocol ValidationBannerViewDelegate: AnyObject {
    func validationBanner(_ banner: ValidationBannerView, didSelect issue: OrgValidationIssue)
}
