import AppKit
import GraphicalDomain

@MainActor
final class MainWindowController: NSWindowController, AppModelDelegate {
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

    /// Retained root stacks — locals would be fine as subviews, but keep explicit for layout debugging.
    private let rootRow = NSStackView()
    private let mainColumn = NSStackView()

    private var validationHeight: NSLayoutConstraint?
    private var shownKey: String?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Graphical"
        window.minSize = NSSize(width: 960, height: 640)
        window.center()
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = false
        self.init(window: window)
        model.delegate = self
        buildUI()
        reload()
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

        // Vertical main column: top bar → validation → workspace → status
        mainColumn.orientation = .vertical
        mainColumn.alignment = .width
        mainColumn.spacing = 0
        mainColumn.distribution = .fill
        mainColumn.translatesAutoresizingMaskIntoConstraints = false
        mainColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        mainColumn.addArrangedSubview(topBar)
        mainColumn.addArrangedSubview(validationBanner)
        mainColumn.addArrangedSubview(contentHost)
        mainColumn.addArrangedSubview(statusBar)

        // Horizontal root: rail | main — stack layout cannot collapse the rail width.
        rootRow.orientation = .horizontal
        rootRow.alignment = .top
        rootRow.spacing = 0
        rootRow.distribution = .fill
        rootRow.translatesAutoresizingMaskIntoConstraints = false
        rootRow.setHuggingPriority(.required, for: .horizontal)
        rail.setContentHuggingPriority(.required, for: .horizontal)
        rail.setContentCompressionResistancePriority(.required, for: .horizontal)
        rootRow.addArrangedSubview(rail)
        rootRow.addArrangedSubview(mainColumn)

        content.addSubview(rootRow)
        NSLayoutConstraint.activate([
            rootRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootRow.topAnchor.constraint(equalTo: content.topAnchor),
            rootRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            rail.widthAnchor.constraint(equalToConstant: Theme.railWidth),
            rail.heightAnchor.constraint(equalTo: rootRow.heightAnchor),
            mainColumn.heightAnchor.constraint(equalTo: rootRow.heightAnchor)
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
        runMenu.addItem(withTitle: "Play Graph", action: #selector(menuPlay), keyEquivalent: "r")
        runItem.submenu = runMenu

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

    func appModelDidChange(_ model: AppModel) {
        reload()
    }

    private func reload() {
        rail.reload(from: model)
        topBar.reload(from: model)
        statusBar.update(
            error: model.errorMessage,
            status: model.statusMessage,
            isRunning: model.isRunning,
            hasProject: model.project != nil
        )
        updateValidation()
        showCurrentContent()
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

final class ValidationBannerView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    var preferredHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.warningSoft.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        Theme.applyLabel(label, style: .caption)
        label.textColor = Theme.warning
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setIssues(_ issues: [OrgValidationIssue]) {
        let text = issues.map { "• \($0.message)" }.joined(separator: "\n")
        label.stringValue = text
        let size = label.sizeThatFits(NSSize(width: 800, height: 10_000))
        preferredHeight = max(36, size.height + 16)
    }
}
