import AppKit
import GraphicalDomain

@MainActor
final class OrgWorkspaceController: NSObject {
    var model: AppModel!
    let view = NSView()
    private let canvas = OrgCanvasView()
    private let inspector = OrgInspectorView()
    private let projectGuide = ProjectGuideView()
    private let toolbar = NSStackView()
    private let selectButton: PrimaryButton
    private let fixedButton: PrimaryButton
    private let routerButton: PrimaryButton

    override init() {
        selectButton = PrimaryButton(title: "Select", style: .secondary, target: nil, action: nil)
        fixedButton = PrimaryButton(title: "Connect Steps", style: .secondary, target: nil, action: nil)
        routerButton = PrimaryButton(title: "Add Decision", style: .secondary, target: nil, action: nil)
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor

        canvas.delegate = self
        inspector.delegate = self
        projectGuide.delegate = self

        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = Theme.surface.cgColor

        let run = PrimaryButton(title: "Play", style: .primary, target: self, action: #selector(runGraph))
        run.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        run.imagePosition = .imageLeading
        let addNode = PrimaryButton(title: "Add Step", style: .secondary, target: self, action: #selector(addNode))
        selectButton.target = self
        selectButton.action = #selector(selectTool)
        fixedButton.target = self
        fixedButton.action = #selector(connectFixed)
        routerButton.target = self
        routerButton.action = #selector(connectRouter)
        let fit = PrimaryButton(title: "Fit", style: .secondary, target: self, action: #selector(fitCanvas))
        fit.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fit")
        fit.imagePosition = .imageLeading
        let hint = AppKitText.label("⌘-drag pan · ⌘-scroll zoom · Del delete", style: .muted)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(rawValue: 50), for: .horizontal)
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for control in [addNode, selectButton, fixedButton, routerButton, fit, run] as [NSView] {
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        toolbar.addArrangedSubview(addNode)
        toolbar.addArrangedSubview(selectButton)
        toolbar.addArrangedSubview(fixedButton)
        toolbar.addArrangedSubview(routerButton)
        toolbar.addArrangedSubview(fit)
        toolbar.addArrangedSubview(hint)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(run)
        toolbar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.clipsToBounds = true

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        canvas.setContentHuggingPriority(.defaultLow, for: .horizontal)
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Canvas under chrome so a bad frame cannot paint over the toolbar/inspector.
        // Guide floats over the canvas as a compact card (not a full-width band).
        view.addSubview(canvas)
        view.addSubview(toolbar)
        view.addSubview(border)
        view.addSubview(projectGuide)
        view.addSubview(inspector)

        inspector.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        inspector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Keep the floating card from stretching, but never higher than the
        // edge pins on `view` / canvas — `.required` hugging was able to win
        // fights and collapse the workspace into a trailing strip.
        projectGuide.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Prefer shrinking the card over forcing the window past the display.
        projectGuide.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: Theme.inspectorWidth)
        inspectorWidth.priority = .defaultHigh
        let guideWidth = projectGuide.widthAnchor.constraint(equalToConstant: 280)
        guideWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            inspector.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: view.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inspectorWidth,
            inspector.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.38),
            inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

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
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Compact readiness card: trailing-aligned over the canvas.
            projectGuide.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -8),
            projectGuide.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 8),
            projectGuide.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 8),
            guideWidth,
            projectGuide.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            projectGuide.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    func statusHint(for model: AppModel) -> String? {
        guard model.selectedTab == .org else { return nil }
        switch canvas.tool {
        case .select:
            return nil
        case .connectFixed:
            return "Connect Steps armed — click a step, then click the next step"
        case .connectRouter:
            return "Add Decision armed — click source step, then each possible target"
        }
    }

    func reload() {
        guard let project = model.project else { return }
        if let readiness = model.projectReadiness {
            projectGuide.reload(readiness: readiness, projectRoot: project.root)
        }
        canvas.configure(
            org: project.org,
            layout: model.layout,
            selectedNodeId: model.selectedNodeId,
            selectedEdgeId: model.selectedEdgeId,
            activeRunNodeId: resolvedActiveRunNodeId(from: model),
            runPaused: model.run?.status == .awaitingApproval
        )
        syncToolButtons()
        if model.consumeFitCanvasRequest() {
            canvas.fitToContent()
        } else if model.shouldCenterSelection {
            centerSelection(in: project.org)
            model.consumeCenterSelectionRequest()
        }
        inspector.reload(
            projectName: project.config.name,
            goal: model.goalDraft,
            org: project.org,
            runners: project.runners,
            selectedNodeId: model.selectedNodeId,
            selectedEdgeId: model.selectedEdgeId
        )
    }

    func reloadRunHighlight() {
        guard model.project != nil else { return }
        canvas.setActiveRunHighlight(
            nodeId: resolvedActiveRunNodeId(from: model),
            paused: model.run?.status == .awaitingApproval
        )
    }

    private func resolvedActiveRunNodeId(from model: AppModel) -> String? {
        guard model.isRunning || model.run?.status == .awaitingApproval else { return nil }
        return model.run?.activeNodeId
    }

    private func centerSelection(in org: OrgGraph) {
        if let nodeId = model.selectedNodeId {
            canvas.centerOn(nodeId: nodeId)
        } else if let edgeId = model.selectedEdgeId,
                  let edge = org.edges.first(where: { $0.id == edgeId }) {
            canvas.centerOn(nodeId: edge.from)
        }
    }

    private func syncToolButtons() {
        selectButton.isActive = canvas.tool == .select
        fixedButton.isActive = canvas.tool == .connectFixed
        routerButton.isActive = canvas.tool == .connectRouter
    }

    private func toolDidChange() {
        syncToolButtons()
        model.notify()
    }

    @objc private func addNode() { model.addNode() }
    @objc private func selectTool() {
        canvas.setTool(.select)
        toolDidChange()
    }
    @objc private func connectFixed() {
        canvas.setTool(canvas.tool == .connectFixed ? .select : .connectFixed)
        toolDidChange()
    }
    @objc private func connectRouter() {
        canvas.setTool(canvas.tool == .connectRouter ? .select : .connectRouter)
        toolDidChange()
    }
    @objc private func fitCanvas() { model.requestFitCanvas() }
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
            model.addRouterEdge(from: from, to: to)
        } else {
            model.addFixedEdge(from: from, to: to)
        }
        canvas.setTool(.select)
        toolDidChange()
    }

    func orgCanvasDidRequestDeleteSelection(_ canvas: OrgCanvasView) {
        model.deleteSelection()
    }

    func orgCanvasDidRequestCancelConnect(_ canvas: OrgCanvasView) {
        toolDidChange()
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

    func orgInspector(_ inspector: OrgInspectorView, didMirrorAgentAndModelFrom sourceId: String) {
        model.mirrorAgentAndModel(from: sourceId)
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
        if let project = model.project, let readiness = model.projectReadiness {
            projectGuide.reload(readiness: readiness, projectRoot: project.root)
        }
    }
}

extension OrgWorkspaceController: ProjectGuideViewDelegate {
    func projectGuide(_ guide: ProjectGuideView, didRequest action: ProjectGuideView.Action) {
        switch action {
        case .setGoal:
            model.showRunGoalEditor()
        case .chooseTool:
            model.requestCodingToolSetup()
        case .fixWorkflow:
            if let issue = model.validationIssues.first {
                model.focusValidationIssue(issue)
            } else {
                model.selectedTab = .org
            }
        case .run:
            model.play()
        }
    }
}
