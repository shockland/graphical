import AppKit

@MainActor
protocol EmptyStateViewDelegate: AnyObject {
    func emptyStateDidOpen(_ view: EmptyStateView)
    func emptyStateDidCreate(_ view: EmptyStateView)
}

final class EmptyStateView: NSView {
    weak var delegate: EmptyStateViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = AppIcon.image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let brand = AppKitText.label("Graphical", style: .brand)
        brand.alignment = .center

        let subtitle = AppKitText.label(
            "Describe a result, choose a coding tool, and Graphical guides Planner → Implementer → Reviewer.",
            style: .body
        )
        subtitle.textColor = Theme.muted
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3

        let create = PrimaryButton(title: "Create Project…", style: .primary, target: self, action: #selector(createTapped))
        let open = PrimaryButton(title: "Open Existing…", style: .secondary, target: self, action: #selector(openTapped))

        let actions = NSStackView(views: [create, open])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false

        let hints = AppKitText.label("⌘O Open · ⌘N Create · ⌘S Save · ⌘R Run", style: .caption)
        hints.textColor = Theme.muted.withAlphaComponent(0.85)
        hints.alignment = .center

        let stack = NSStackView(views: [iconView, brand, subtitle, actions, hints])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openTapped() { delegate?.emptyStateDidOpen(self) }
    @objc private func createTapped() { delegate?.emptyStateDidCreate(self) }
}
