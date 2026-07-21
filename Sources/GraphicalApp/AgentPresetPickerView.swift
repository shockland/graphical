import AppKit
import GraphicalCLI

final class AgentPresetPickerView: NSView {
    enum DetectionStatus: Equatable {
        case checking
        case installed(version: String)
        case missing
        case failed

        var text: String {
            switch self {
            case .checking: return "Checking…"
            case .installed(let version): return "Installed — \(version)"
            case .missing: return "Not found"
            case .failed: return "Check failed"
            }
        }

        /// Verified present on this Mac (or built-in demo).
        var isVerifiedInstalled: Bool {
            if case .installed = self { return true }
            return false
        }

        /// Soft-block candidate: user may select and "Use anyway".
        var allowsUseAnyway: Bool {
            switch self {
            case .missing, .failed: return true
            case .checking, .installed: return false
            }
        }
    }

    var onSelectPreset: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onSelectionOrStatusChange: (() -> Void)?

    private let presets = AgentPresetCatalog.all
    private var statuses: [String: DetectionStatus] = [:]
    private var cards: [String: NSButton] = [:]
    private let refreshButton = PrimaryButton(
        title: "Check again",
        style: .secondary,
        target: nil,
        action: nil
    )
    private let installHintLabel = AppKitText.label("", style: .caption)

    private(set) var selectedPresetID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        for preset in presets {
            statuses[preset.id] = preset.id == AgentPresetCatalog.demo.id
                ? .installed(version: "Built in")
                : .checking
        }

        let heading = AppKitText.label("Choose a coding tool", style: .section)
        let header = NSStackView(views: [heading, NSView(), refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.setAccessibilityLabel("Check coding tools again")

        installHintLabel.textColor = Theme.muted
        installHintLabel.maximumNumberOfLines = 3
        installHintLabel.lineBreakMode = .byWordWrapping
        installHintLabel.isHidden = true

        let rows = stride(from: 0, to: presets.count, by: 2).map { start -> [NSView] in
            let end = min(start + 2, presets.count)
            return presets[start..<end].map(makeCard)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<grid.numberOfColumns {
            grid.column(at: index).xPlacement = .fill
        }
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .fill
        }

        let stack = NSStackView(views: [header, grid, installHintLabel])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pinEdges(to: self)

        setSelectedPresetID("demo")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func status(for presetID: String) -> DetectionStatus? {
        statuses[presetID]
    }

    /// Any catalog preset can be chosen (soft-block); Demo always; checking still selectable.
    func isPresetSelectable(_ presetID: String?) -> Bool {
        guard let presetID, AgentPresetCatalog.preset(id: presetID) != nil else {
            return false
        }
        return true
    }

    func isSelectedPresetVerifiedInstalled() -> Bool {
        guard let selectedPresetID else { return false }
        if selectedPresetID == AgentPresetCatalog.demo.id { return true }
        return statuses[selectedPresetID]?.isVerifiedInstalled == true
    }

    func selectedPresetNeedsUseAnyway() -> Bool {
        guard let selectedPresetID,
              selectedPresetID != AgentPresetCatalog.demo.id,
              let status = statuses[selectedPresetID] else {
            return false
        }
        return status.allowsUseAnyway
    }

    func selectedPresetIsChecking() -> Bool {
        guard let selectedPresetID,
              selectedPresetID != AgentPresetCatalog.demo.id,
              let status = statuses[selectedPresetID] else {
            return false
        }
        return status == .checking
    }

    func setStatus(_ status: DetectionStatus, for presetID: String) {
        guard AgentPresetCatalog.preset(id: presetID) != nil else { return }
        statuses[presetID] = presetID == AgentPresetCatalog.demo.id
            ? .installed(version: "Built in")
            : status
        refreshCard(presetID)
        updateInstallHint()
        onSelectionOrStatusChange?()
    }

    func setSelectedPresetID(_ presetID: String?) {
        selectedPresetID = presetID
        for preset in presets {
            refreshCard(preset.id)
        }
        updateInstallHint()
        onSelectionOrStatusChange?()
    }

    private func makeCard(for preset: AgentPreset) -> NSView {
        let card = NSButton(title: "", target: self, action: #selector(cardTapped(_:)))
        card.identifier = NSUserInterfaceItemIdentifier(preset.id)
        card.setButtonType(.toggle)
        card.bezelStyle = .regularSquare
        card.alignment = .left
        card.focusRingType = .exterior
        card.cell?.wraps = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let minWidth = card.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        // Soft floor — never force the setup sheet wider than the screen.
        minWidth.priority = .defaultLow
        minWidth.isActive = true
        cards[preset.id] = card
        refreshCard(preset.id)
        return card
    }

    private func refreshCard(_ presetID: String) {
        guard let preset = AgentPresetCatalog.preset(id: presetID),
              let card = cards[presetID],
              let status = statuses[presetID] else {
            return
        }
        let isSelected = selectedPresetID == presetID
        let selectionText = isSelected ? "Selected · " : ""
        let text = """
        \(preset.displayName)
        \(preset.displayDescription)
        \(selectionText)\(status.text)
        """
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 2
        let emphasis = status.isVerifiedInstalled || presetID == AgentPresetCatalog.demo.id
        card.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: Theme.bodyFont(ofSize: 12),
                .foregroundColor: emphasis ? Theme.text : Theme.muted,
                .paragraphStyle: paragraph
            ]
        )
        card.contentTintColor = nil
        card.state = isSelected ? .on : .off
        card.bezelColor = isSelected ? Theme.buttonSecondaryActiveFill : Theme.surface
        card.isEnabled = true
        card.toolTip = "\(preset.displayName). \(status.text)."
        card.setAccessibilityLabel(preset.displayName)
        card.setAccessibilityHelp("\(preset.displayDescription) \(status.text).")
        card.setAccessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func updateInstallHint() {
        guard let selectedPresetID,
              let preset = AgentPresetCatalog.preset(id: selectedPresetID),
              let hint = preset.installHint,
              let status = statuses[selectedPresetID],
              status.allowsUseAnyway else {
            installHintLabel.stringValue = ""
            installHintLabel.isHidden = true
            return
        }
        installHintLabel.stringValue = hint
        installHintLabel.isHidden = false
    }

    @objc private func cardTapped(_ sender: NSButton) {
        guard let presetID = sender.identifier?.rawValue,
              isPresetSelectable(presetID) else {
            sender.state = .off
            return
        }
        setSelectedPresetID(presetID)
        onSelectPreset?(presetID)
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }
}
