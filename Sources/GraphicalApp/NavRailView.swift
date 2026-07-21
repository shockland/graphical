import AppKit
import GraphicalDomain

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
    private let recentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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

        // Preferred width is owned by MainWindowController; allow soft shrink on
        // very narrow windows instead of overflowing the screen.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        createBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
                recentStack.addArrangedSubview(makeRecentRunButton(run))
            }
        }

        updateSelectionAppearance()
    }

    /// Cheap update for run-progress ticks (plans/013): only the Run tab's running
    /// dot needs to change on most ticks, so avoid `reload(from:)`'s recent-runs
    /// subview teardown/rebuild.
    func updateRunningIndicator(isRunning: Bool) {
        guard self.isRunning != isRunning else { return }
        self.isRunning = isRunning
        updateSelectionAppearance()
    }

    private func makeRecentRunButton(_ run: RunRecord) -> NSView {
        let shortId = String(run.id.prefix(8))
        let preview = run.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle: String
        if preview.isEmpty {
            subtitle = recentDateFormatter.string(from: run.createdAt)
        } else if preview.count > 28 {
            subtitle = String(preview.prefix(28)) + "…"
        } else {
            subtitle = preview
        }
        let statusColor = colorForRunStatus(run.status)
        let symbol = symbolForRunStatus(run.status)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: run.status.rawValue)
        icon.contentTintColor = statusColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = AppKitText.label(shortId, style: .caption)
        titleLabel.textColor = statusColor
        titleLabel.font = Theme.bodyFont(ofSize: 11, weight: .semibold)

        let subtitleLabel = AppKitText.label(subtitle, style: .caption)
        subtitleLabel.textColor = Theme.muted
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        let button = NSButton(title: "", target: self, action: #selector(recentTapped(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.identifier = NSUserInterfaceItemIdentifier(run.id)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            row.topAnchor.constraint(equalTo: button.topAnchor),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
        return button
    }

    private func colorForRunStatus(_ status: RunStatus) -> NSColor {
        switch status {
        case .succeeded:
            return Theme.accent
        case .failed:
            return Theme.danger
        case .cancelled:
            return Theme.muted
        case .running, .pending, .awaitingApproval:
            return Theme.warning
        }
    }

    private func symbolForRunStatus(_ status: RunStatus) -> String {
        switch status {
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "stop.circle"
        case .running, .pending:
            return "play.circle.fill"
        case .awaitingApproval:
            return "hand.raised.fill"
        }
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
        // Fill the rail column instead of a hard-coded width that fights shrink.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
