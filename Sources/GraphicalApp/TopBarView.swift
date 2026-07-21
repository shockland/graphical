import AppKit

@MainActor
protocol TopBarViewDelegate: AnyObject {
    func topBarDidOpen(_ bar: TopBarView)
    func topBarDidCreate(_ bar: TopBarView)
    func topBarDidClose(_ bar: TopBarView)
    func topBarDidSave(_ bar: TopBarView)
    func topBarDidRun(_ bar: TopBarView)
}

final class TopBarView: NSView {
    weak var delegate: TopBarViewDelegate?

    private let titleLabel = AppKitText.label("Workflow", style: .section)
    private let pathLabel = AppKitText.label("", style: .muted)
    private let unsavedLabel = AppKitText.label("Unsaved", style: .caption)
    private lazy var openButton = PrimaryButton(title: "Open…", style: .secondary, target: self, action: #selector(openTapped))
    private lazy var createButton = PrimaryButton(title: "Create…", style: .secondary, target: self, action: #selector(createTapped))
    private lazy var closeButton = PrimaryButton(title: "Close", style: .secondary, target: self, action: #selector(closeTapped))
    private lazy var saveButton = PrimaryButton(title: "Save", style: .secondary, target: self, action: #selector(saveTapped))
    private lazy var runButton = PrimaryButton(title: "Play", style: .primary, target: self, action: #selector(runTapped))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        unsavedLabel.textColor = Theme.warning
        unsavedLabel.isHidden = true
        unsavedLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        runButton.imagePosition = .imageLeading

        let stack = NSStackView(views: [openButton, createButton, closeButton, saveButton, unsavedLabel, runButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Soft compress so the bar never forces the window past the screen;
        // path truncates first, then secondary actions can clip.
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.setHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for control in [openButton, createButton, closeButton, saveButton, runButton] as [NSView] {
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        addSubview(border)
        addSubview(titleLabel)
        addSubview(pathLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.topBarHeight),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -12),

            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Keep actions on-screen; path truncates before buttons overflow.
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload(from model: AppModel) {
        titleLabel.stringValue = model.selectedTab.rawValue
        pathLabel.stringValue = model.project?.root.path ?? ""
        let hasProject = model.project != nil
        let running = model.isRunning
        openButton.isHidden = hasProject
        createButton.isHidden = hasProject
        closeButton.isHidden = true
        saveButton.isEnabled = hasProject
        saveButton.isHidden = !hasProject
        unsavedLabel.isHidden = !hasProject || !model.hasUnsavedChanges
        runButton.isEnabled = hasProject && !running
        runButton.isHidden = !hasProject
        if running {
            runButton.title = "Running…"
            runButton.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Running")
        } else {
            runButton.title = "Play"
            runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        }
    }

    @objc private func openTapped() { delegate?.topBarDidOpen(self) }
    @objc private func createTapped() { delegate?.topBarDidCreate(self) }
    @objc private func closeTapped() { delegate?.topBarDidClose(self) }
    @objc private func saveTapped() { delegate?.topBarDidSave(self) }
    @objc private func runTapped() { delegate?.topBarDidRun(self) }
}
