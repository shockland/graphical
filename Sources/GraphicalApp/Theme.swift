import AppKit

enum Theme {
    static let background = NSColor(srgbRed: 0.957, green: 0.965, blue: 0.973, alpha: 1) // #F4F6F8
    static let surface = NSColor.white
    /// Distinct from the canvas so the left rail cannot blend into the grid.
    static let rail = NSColor(srgbRed: 0.898, green: 0.906, blue: 0.922, alpha: 1) // #E5E7EB
    static let border = NSColor(srgbRed: 0.886, green: 0.910, blue: 0.941, alpha: 1) // #E2E8F0
    static let borderStrong = NSColor(srgbRed: 0.796, green: 0.835, blue: 0.882, alpha: 1) // #CBD5E1
    static let text = NSColor(srgbRed: 0.059, green: 0.090, blue: 0.165, alpha: 1) // #0F172A
    static let muted = NSColor(srgbRed: 0.278, green: 0.333, blue: 0.412, alpha: 1) // #475569
    static let accent = NSColor(srgbRed: 0.051, green: 0.580, blue: 0.533, alpha: 1) // #0D9488
    static let accentSoft = NSColor(srgbRed: 0.051, green: 0.580, blue: 0.533, alpha: 0.12)
    static let danger = NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1) // #DC2626
    static let warning = NSColor(srgbRed: 0.851, green: 0.469, blue: 0.024, alpha: 1) // #D97706
    static let warningSoft = NSColor(srgbRed: 0.851, green: 0.469, blue: 0.024, alpha: 0.12)

    /// Paired button fill/label tokens — choose labels for the fill they sit on.
    static let onAccentLabel = NSColor.white
    static let buttonDisabledFill = NSColor(srgbRed: 0.749, green: 0.863, blue: 0.847, alpha: 1) // #BFDCD8
    static let buttonDisabledDangerFill = NSColor(srgbRed: 0.957, green: 0.820, blue: 0.820, alpha: 1) // #F4D1D1
    static let buttonDisabledLabel = muted
    static let buttonSecondaryFill = rail
    static let buttonSecondaryLabel = text
    static let buttonSecondaryActiveFill = accentSoft
    static let buttonSecondaryActiveLabel = text
    static let buttonGhostLabel = text
    static let buttonGhostDisabledLabel = NSColor(srgbRed: 0.278, green: 0.333, blue: 0.412, alpha: 0.72)

    static let railWidth: CGFloat = 180
    static let inspectorWidth: CGFloat = 260
    static let topBarHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let nodeShadowOpacity: CGFloat = 0.08
    static let nodeShadowRadius: CGFloat = 6
    static let nodeShadowOffset = CGSize(width: 0, height: 2)

    static let nodeMinWidth: CGFloat = 160
    static let nodeMinHeight: CGFloat = 56
    static let nodeMaxWidth: CGFloat = 260
    static let nodePaddingH: CGFloat = 14
    static let nodePaddingV: CGFloat = 10
    static let nodeRowSpacing: CGFloat = 4
    static let nodeContentInsetLeft: CGFloat = 14
    static let nodeEntryBarWidth: CGFloat = 5
    static let nodeChipCornerRadius: CGFloat = 4
    static let nodeBadgeCornerRadius: CGFloat = 4
    static let nodeRoleFontSize: CGFloat = 13
    static let nodeMetaFontSize: CGFloat = 11
    static let nodeChipFontSize: CGFloat = 10
    static let nodeBadgeFontSize: CGFloat = 9
    static let nodeStartFontSize: CGFloat = 8
    static let nodeChipPaddingH: CGFloat = 5
    static let nodeChipPaddingV: CGFloat = 2
    static let nodeBadgePaddingH: CGFloat = 5
    static let nodeBadgePaddingV: CGFloat = 2

    static func bodyFont(ofSize size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(ofSize size: CGFloat = 11) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func applyLabel(_ label: NSTextField, style: LabelStyle) {
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = style == .muted ? muted : text
        switch style {
        case .brand:
            label.font = bodyFont(ofSize: 28, weight: .bold)
        case .title:
            label.font = bodyFont(ofSize: 15, weight: .semibold)
        case .section:
            label.font = bodyFont(ofSize: 13, weight: .semibold)
        case .body:
            label.font = bodyFont(ofSize: 13)
        case .caption, .muted:
            label.font = bodyFont(ofSize: 11)
            if style == .muted { label.textColor = muted }
        case .mono:
            label.font = monoFont(ofSize: 11)
        }
    }

    enum LabelStyle {
        case brand, title, section, body, caption, muted, mono
    }
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        ])
    }

    func pinEdges(toGuide guide: NSLayoutGuide, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: guide.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom)
        ])
    }
}
