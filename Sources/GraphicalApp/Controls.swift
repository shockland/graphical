import AppKit

final class PrimaryButton: NSButton {
    enum Style {
        case primary
        case secondary
        case danger
        case ghost
    }

    private let style: Style

    init(title: String, style: Style = .secondary, target: AnyObject?, action: Selector?) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        font = Theme.bodyFont(ofSize: 13, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        isBordered = true
        switch style {
        case .primary:
            bezelColor = Theme.accent
            contentTintColor = .white
        case .secondary:
            bezelColor = Theme.surface
            contentTintColor = Theme.text
        case .danger:
            bezelColor = Theme.danger
            contentTintColor = .white
        case .ghost:
            isBordered = false
            contentTintColor = Theme.muted
        }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setLines(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        textView.string = text
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
