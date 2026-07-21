import AppKit

@MainActor
protocol NavRailViewDelegate: AnyObject {
    func navRail(_ rail: NavRailView, didSelect tab: AppModel.AppTab)
    func navRailDidSelectOpen(_ rail: NavRailView)
    func navRailDidSelectCreate(_ rail: NavRailView)
    func navRailDidSelectClose(_ rail: NavRailView)
    func navRail(_ rail: NavRailView, didSelectRun runId: String)
}

final class NavRailView: NSView {
    weak var delegate: NavRailViewDelegate?

    private let brandLabel = AppKitText.label("Graphical", style: .title)
    private let projectLabel = AppKitText.label("No project", style: .muted)
    private let navHintLabel = AppKitText.label("Open a project to navigate", style: .caption)
    private lazy var closeProjectButton = PrimaryButton(
        title: "Close Project",
        style: .ghost,
        target: self,
        action: #selector(closeTapped)
    )
    private let projectHeader = NSStackView()
    private var tabButtons: [AppModel.AppTab: NSButton] = [:]
    private let tabsStack = NSStackView()
    private let recentTitle = AppKitText.label("Recent runs", style: .caption)
    private let recentStack = NSStackView()
    private lazy var openBtn = PrimaryButton(title: "Open…", style: .ghost, target: self, action: #selector(openTapped))
    private lazy var createBtn = PrimaryButton(title: "Create…", style: .ghost, target: self, action: #selector(createTapped))
    private var currentTab: AppModel.AppTab = .org
    private var hasProject = false
    private var isRunning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.rail.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderStrong.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false

        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.maximumNumberOfLines = 2
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navHintLabel.textColor = Theme.muted
        navHintLabel.translatesAutoresizingMaskIntoConstraints = false
        navHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tabsStack.orientation = .vertical
        tabsStack.alignment = .leading
        tabsStack.spacing = 4
        tabsStack.translatesAutoresizingMaskIntoConstraints = false

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2
        recentStack.translatesAutoresizingMaskIntoConstraints = false

        for tab in AppModel.AppTab.allCases {
            let button = makeTabButton(tab)
            tabButtons[tab] = button
            tabsStack.addArrangedSubview(button)
        }

        recentTitle.textColor = Theme.muted
        recentTitle.translatesAutoresizingMaskIntoConstraints = false

        closeProjectButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Project")
        closeProjectButton.imagePosition = .imageLeading
        closeProjectButton.isHidden = true

        projectHeader.orientation = .vertical
        projectHeader.alignment = .leading
        projectHeader.spacing = 2
        projectHeader.translatesAutoresizingMaskIntoConstraints = false
        projectHeader.addArrangedSubview(projectLabel)
        projectHeader.addArrangedSubview(closeProjectButton)

        addSubview(border)
        addSubview(brandLabel)
        addSubview(projectHeader)
        addSubview(navHintLabel)
        addSubview(tabsStack)
        addSubview(recentTitle)
        addSubview(recentStack)
        addSubview(openBtn)
        addSubview(createBtn)

        // Width is owned by MainWindowController so the rail cannot collapse.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.widthAnchor.constraint(equalToConstant: 1),

            brandLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            brandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            brandLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            projectHeader.topAnchor.constraint(equalTo: brandLabel.bottomAnchor, constant: 4),
            projectHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            projectHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            navHintLabel.topAnchor.constraint(equalTo: projectHeader.bottomAnchor, constant: 16),
            navHintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            navHintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            tabsStack.topAnchor.constraint(equalTo: navHintLabel.bottomAnchor, constant: 10),
            tabsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            recentTitle.topAnchor.constraint(equalTo: tabsStack.bottomAnchor, constant: 28),
            recentTitle.leadingAnchor.constraint(equalTo: brandLabel.leadingAnchor),

            recentStack.topAnchor.constraint(equalTo: recentTitle.bottomAnchor, constant: 8),
            recentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            recentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            openBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            createBtn.leadingAnchor.constraint(equalTo: openBtn.trailingAnchor, constant: 4),
            openBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            createBtn.bottomAnchor.constraint(equalTo: openBtn.bottomAnchor)
        ])

        updateSelectionAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload(from model: AppModel) {
        currentTab = model.selectedTab
        hasProject = model.project != nil
        isRunning = model.isRunning
        if let name = model.project?.config.name {
            projectLabel.stringValue = name
            projectLabel.textColor = Theme.text
        } else {
            projectLabel.stringValue = "No project"
            projectLabel.textColor = Theme.muted
        }
        closeProjectButton.isHidden = !hasProject
        navHintLabel.isHidden = hasProject
        // Demote Open/Create when a project is loaded so tabs stay primary.
        openBtn.alphaValue = hasProject ? 0.55 : 1
        createBtn.alphaValue = hasProject ? 0.55 : 1
        recentTitle.isHidden = !hasProject
        recentStack.isHidden = !hasProject

        recentStack.arrangedSubviews.forEach {
            recentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if hasProject {
            for run in model.recentRuns.prefix(6) {
                let btn = NSButton(
                    title: "\(run.status.rawValue) · \(run.id.prefix(8))",
                    target: self,
                    action: #selector(recentTapped(_:))
                )
                btn.bezelStyle = .inline
                btn.isBordered = false
                btn.font = Theme.bodyFont(ofSize: 11)
                btn.contentTintColor = Theme.muted
                btn.alignment = .left
                btn.identifier = NSUserInterfaceItemIdentifier(run.id)
                btn.translatesAutoresizingMaskIntoConstraints = false
                recentStack.addArrangedSubview(btn)
            }
        }

        updateSelectionAppearance()
    }

    private func makeTabButton(_ tab: AppModel.AppTab) -> NSButton {
        let button = NSButton(title: "  \(tab.rawValue)", target: self, action: #selector(tabTapped(_:)))
        button.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.rawValue)
        button.imagePosition = .imageLeading
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = Theme.bodyFont(ofSize: 13, weight: .medium)
        button.alignment = .left
        button.identifier = NSUserInterfaceItemIdentifier(tab.rawValue)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.controlRadius
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.widthAnchor.constraint(equalToConstant: Theme.railWidth - 24).isActive = true
        return button
    }

    private func updateSelectionAppearance() {
        for (tab, button) in tabButtons {
            let selected = hasProject && tab == currentTab
            button.isEnabled = hasProject
            button.alphaValue = hasProject ? 1 : 0.45
            let title = tab == .run && isRunning ? "\(tab.rawValue) ●" : tab.rawValue
            if selected {
                button.layer?.backgroundColor = Theme.accentSoft.cgColor
                button.contentTintColor = Theme.accent
                button.attributedTitle = attributedTabTitle(title, color: Theme.accent, selected: true)
            } else {
                button.layer?.backgroundColor = NSColor.clear.cgColor
                let color = tab == .run && isRunning ? Theme.accent : (hasProject ? Theme.text : Theme.muted)
                button.contentTintColor = color
                button.attributedTitle = attributedTabTitle(
                    title,
                    color: color,
                    selected: false
                )
            }
        }
    }

    private func attributedTabTitle(_ title: String, color: NSColor, selected: Bool) -> NSAttributedString {
        NSAttributedString(
            string: "  \(title)",
            attributes: [
                .font: Theme.bodyFont(ofSize: 13, weight: selected ? .semibold : .medium),
                .foregroundColor: color
            ]
        )
    }

    @objc private func tabTapped(_ sender: NSButton) {
        guard hasProject else { return }
        guard let raw = sender.identifier?.rawValue,
              let tab = AppModel.AppTab(rawValue: raw) else { return }
        currentTab = tab
        updateSelectionAppearance()
        delegate?.navRail(self, didSelect: tab)
    }

    @objc private func openTapped() { delegate?.navRailDidSelectOpen(self) }
    @objc private func createTapped() { delegate?.navRailDidSelectCreate(self) }
    @objc private func closeTapped() { delegate?.navRailDidSelectClose(self) }

    @objc private func recentTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        delegate?.navRail(self, didSelectRun: id)
    }
}
