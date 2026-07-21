import AppKit
import GraphicalDomain

@MainActor
final class OrgWorkspaceController: NSObject {
    var model: AppModel!
    let view = NSView()
    private let canvas = OrgCanvasView()
    private let inspector = OrgInspectorView()
    private let toolbar = NSStackView()

    override init() {
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor

        canvas.delegate = self
        inspector.delegate = self

        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = Theme.surface.cgColor

        let run = PrimaryButton(title: "Play", style: .primary, target: self, action: #selector(runGraph))
        run.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        run.imagePosition = .imageLeading
        let addNode = PrimaryButton(title: "Add Node", style: .secondary, target: self, action: #selector(addNode))
        let fixed = PrimaryButton(title: "Connect Fixed", style: .secondary, target: self, action: #selector(connectFixed))
        let router = PrimaryButton(title: "Connect Router", style: .secondary, target: self, action: #selector(connectRouter))
        let hint = AppKitText.label("⌘-drag to pan · ⌘-scroll to zoom", style: .muted)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(addNode)
        toolbar.addArrangedSubview(fixed)
        toolbar.addArrangedSubview(router)
        toolbar.addArrangedSubview(hint)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(run)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        view.clipsToBounds = true
        // Canvas under chrome so a bad frame cannot paint over the toolbar/inspector.
        view.addSubview(canvas)
        view.addSubview(toolbar)
        view.addSubview(border)
        view.addSubview(inspector)

        inspector.setContentHuggingPriority(.required, for: .horizontal)
        inspector.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            inspector.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: view.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: Theme.inspectorWidth),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            border.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            border.topAnchor.constraint(equalTo: toolbar.bottomAnchor),

            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: border.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func reload() {
        guard let project = model.project else { return }
        canvas.configure(
            org: project.org,
            layout: model.layout,
            selectedNodeId: model.selectedNodeId,
            selectedEdgeId: model.selectedEdgeId,
            activeRunNodeId: model.isRunning ? model.run?.activeNodeId : nil
        )
        inspector.reload(
            projectName: project.config.name,
            goal: model.goalDraft,
            org: project.org,
            runners: project.runners,
            selectedNodeId: model.selectedNodeId,
            selectedEdgeId: model.selectedEdgeId
        )
    }

    @objc private func addNode() { model.addNode() }
    @objc private func connectFixed() { canvas.setTool(.connectFixed) }
    @objc private func connectRouter() { canvas.setTool(.connectRouter) }
    @objc private func runGraph() {
        model.play()
    }
}

extension OrgWorkspaceController: OrgCanvasViewDelegate {
    func orgCanvasDidChangeSelection(_ canvas: OrgCanvasView) {
        model.selectedNodeId = canvas.selectedNodeId
        model.selectedEdgeId = canvas.selectedEdgeId
        model.notify()
    }

    func orgCanvas(_ canvas: OrgCanvasView, didMoveNode id: String, to point: CGPoint, ended: Bool) {
        model.setNodePosition(id: id, x: point.x, y: point.y, persist: ended)
    }

    func orgCanvasDidRequestAddNode(_ canvas: OrgCanvasView) {
        model.addNode()
    }

    func orgCanvas(_ canvas: OrgCanvasView, didCreateEdgeFrom from: String, to: String, router: Bool) {
        if router {
            model.addRouterEdge(from: from)
            if let edge = model.project?.org.edges.last(where: { $0.from == from && $0.type == .router }) {
                model.replaceEdge(
                    OrgEdge(
                        id: edge.id,
                        from: from,
                        type: .router,
                        targets: [to],
                        on: edge.on,
                        pass: edge.pass,
                        requiresApproval: edge.requiresApproval
                    )
                )
            }
        } else {
            model.addFixedEdge(from: from, to: to)
        }
    }
}

extension OrgWorkspaceController: OrgInspectorViewDelegate {
    func orgInspector(_ inspector: OrgInspectorView, didUpdateNode node: OrgNode) {
        model.replaceNode(node)
    }

    func orgInspector(_ inspector: OrgInspectorView, didDeleteNode id: String) {
        model.deleteNode(id: id)
    }

    func orgInspector(_ inspector: OrgInspectorView, didMakeEntry id: String) {
        model.setEntry(id)
    }

    func orgInspector(_ inspector: OrgInspectorView, didUpdateEdge edge: OrgEdge) {
        model.replaceEdge(edge)
    }

    func orgInspector(_ inspector: OrgInspectorView, didDeleteEdge id: String) {
        model.deleteEdge(id: id)
    }

    func orgInspector(_ inspector: OrgInspectorView, didUpdateProjectName name: String) {
        model.updateProjectName(name)
    }

    func orgInspector(_ inspector: OrgInspectorView, didUpdateGoal goal: String) {
        model.goalDraft = goal
    }
}
