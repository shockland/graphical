import AppKit

final class PrimaryButton: NSButton {
    enum Style {
        case primary
        case secondary
        case danger
        case ghost
    }

    private let style: Style
    private var displayTitle: String
    var isActive = false {
        didSet { applyStyle() }
    }

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    override var title: String {
        get { displayTitle }
        set {
            displayTitle = newValue
            applyStyle()
        }
    }

    init(title: String, style: Style = .secondary, target: AnyObject?, action: Selector?) {
        self.style = style
        self.displayTitle = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .rounded
        font = Theme.bodyFont(ofSize: 13, weight: .medium)
        // Keep title/icon colors under our control; AppKit's default disabled
        // wash can bleach labels to near-white on light fills.
        (cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        let enabled = isEnabled
        let font = Theme.bodyFont(ofSize: 13, weight: .medium)
        let titleColor: NSColor
        let tint: NSColor

        isBordered = true
        switch style {
        case .primary:
            bezelColor = enabled ? Theme.accent : Theme.accent.withAlphaComponent(0.45)
            titleColor = .white
            tint = .white
        case .secondary:
            if isActive {
                bezelColor = Theme.accentSoft
                titleColor = Theme.accent
                tint = Theme.accent
            } else {
                // Distinct from the page background so labels stay readable.
                bezelColor = Theme.rail
                titleColor = enabled ? Theme.text : Theme.muted
                tint = titleColor
            }
        case .danger:
            bezelColor = enabled ? Theme.danger : Theme.danger.withAlphaComponent(0.45)
            titleColor = .white
            tint = .white
        case .ghost:
            isBordered = false
            bezelColor = nil
            titleColor = enabled ? Theme.muted : Theme.muted.withAlphaComponent(0.55)
            tint = titleColor
        }

        contentTintColor = tint
        attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: font,
                .foregroundColor: titleColor
            ]
        )
    }
}

final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "Ready")
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        Theme.applyLabel(label, style: .muted)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        addSubview(border)
        addSubview(label)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.statusBarHeight),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(error: String?, status: String?, isRunning: Bool, hasProject: Bool) {
        if let error {
            label.stringValue = error
            label.textColor = Theme.danger
        } else if let status {
            label.stringValue = status
            label.textColor = Theme.muted
        } else {
            label.stringValue = hasProject ? "Project loaded" : "Ready"
            label.textColor = Theme.muted
        }
        if isRunning {
            spinner.startAnimation(nil)
            label.textColor = Theme.accent
        } else {
            spinner.stopAnimation(nil)
            if error == nil {
                label.textColor = Theme.muted
            }
        }
    }
}

final class MonoLogView: NSScrollView {
    private let textView = NSTextView()
    private let jumpButton = NSButton(title: "", target: nil, action: nil)
    /// Count of lines already rendered, so `appendLines` can add only the new
    /// suffix instead of replacing the whole string every progress tick (plans/013).
    /// `RunEngine.liveLog` is append-only within a run (see `RunEngine.log`), so a
    /// smaller incoming count only happens when a new run has reset the log.
    private var renderedLineCount = 0
    private var pendingNewLines = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        borderType = .bezelBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = Theme.surface

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Theme.monoFont(ofSize: 11)
        textView.textColor = Theme.text
        textView.backgroundColor = Theme.surface
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        documentView = textView

        jumpButton.bezelStyle = .rounded
        jumpButton.font = Theme.bodyFont(ofSize: 11, weight: .medium)
        jumpButton.target = self
        jumpButton.action = #selector(jumpToBottom)
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpButton)
        NSLayoutConstraint.activate([
            jumpButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            jumpButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isScrolledToBottom: Bool {
        let visible = contentView.documentVisibleRect
        let docHeight = textView.bounds.height
        return visible.maxY >= docHeight - 6
    }

    /// Full replace: use on tab entry / project switch / whenever the log may have
    /// been reset out from under the view.
    func setLines(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        textView.string = text
        renderedLineCount = lines.count
        pendingNewLines = 0
        jumpButton.isHidden = true
        textView.scrollToEndOfDocument(nil)
    }

    /// Append-only update for run-progress ticks. Falls back to a full replace if
    /// `lines` is shorter than what is rendered (log reset by a new run).
    func appendLines(_ lines: [String]) {
        guard lines.count != renderedLineCount else { return }
        guard lines.count > renderedLineCount else {
            setLines(lines)
            return
        }
        let atBottom = isScrolledToBottom
        let newLines = lines[renderedLineCount...]
        let separator = renderedLineCount == 0 ? "" : "\n"
        let appended = separator + newLines.joined(separator: "\n")
        let attributed = NSAttributedString(
            string: appended,
            attributes: [.font: textView.font ?? Theme.monoFont(ofSize: 11), .foregroundColor: textView.textColor ?? Theme.text]
        )
        textView.textStorage?.append(attributed)
        renderedLineCount = lines.count
        if atBottom {
            pendingNewLines = 0
            jumpButton.isHidden = true
            textView.scrollToEndOfDocument(nil)
        } else {
            pendingNewLines += newLines.count
            jumpButton.title = "↓ \(pendingNewLines) new line\(pendingNewLines == 1 ? "" : "s")"
            jumpButton.isHidden = false
        }
    }

    @objc private func jumpToBottom() {
        pendingNewLines = 0
        jumpButton.isHidden = true
        textView.scrollToEndOfDocument(nil)
    }
}

final class FormField: NSView {
    let label: NSTextField
    let control: NSView

    init(title: String, control: NSView) {
        self.label = NSTextField(labelWithString: title)
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        Theme.applyLabel(label, style: .caption)
        label.textColor = Theme.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(label)
        addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            control.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

enum AppKitText {
    static func field(_ value: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.font = Theme.bodyFont()
        field.textColor = Theme.text
        field.backgroundColor = Theme.surface
        field.drawsBackground = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return field
    }

    static func popup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = Theme.bodyFont()
        popup.focusRingType = .exterior
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return popup
    }

    static func label(_ value: String, style: Theme.LabelStyle = .body) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        Theme.applyLabel(field, style: style)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
