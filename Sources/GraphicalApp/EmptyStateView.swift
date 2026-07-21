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

        let brand = AppKitText.label("Graphical", style: .brand)
        brand.alignment = .center

        let subtitle = AppKitText.label(
            "Open or create a project, edit the org on the canvas, then Play to run handoffs from the entry node.",
            style: .body
        )
        subtitle.textColor = Theme.muted
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3

        let open = PrimaryButton(title: "Open Project…", style: .primary, target: self, action: #selector(openTapped))
        let create = PrimaryButton(title: "Create Project…", style: .secondary, target: self, action: #selector(createTapped))

        let actions = NSStackView(views: [open, create])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [brand, subtitle, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openTapped() { delegate?.emptyStateDidOpen(self) }
    @objc private func createTapped() { delegate?.emptyStateDidCreate(self) }
}
