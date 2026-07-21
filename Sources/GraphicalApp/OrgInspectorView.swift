import AppKit
import GraphicalDomain
import GraphicalCLI

@MainActor
protocol OrgInspectorViewDelegate: AnyObject {
    func orgInspector(_ inspector: OrgInspectorView, didUpdateNode node: OrgNode)
    func orgInspector(_ inspector: OrgInspectorView, didDeleteNode id: String)
    func orgInspector(_ inspector: OrgInspectorView, didMakeEntry id: String)
    func orgInspector(_ inspector: OrgInspectorView, didUpdateEdge edge: OrgEdge)
    func orgInspector(_ inspector: OrgInspectorView, didDeleteEdge id: String)
    func orgInspector(_ inspector: OrgInspectorView, didUpdateProjectName name: String)
    func orgInspector(_ inspector: OrgInspectorView, didUpdateGoal goal: String)
}

final class OrgInspectorView: NSView {
    weak var delegate: OrgInspectorViewDelegate?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var nodeIds: [String] = []
    private var currentNode: OrgNode?
    private var currentEdge: OrgEdge?
    private var runners = RunnersConfig()
    private var catalogModels: [CatalogModel] = []
    private var catalogTask: Task<Void, Never>?

    private let nameField = AppKitText.field()
    private let goalView = NSTextView()

    private let nodeIdField = AppKitText.field()
    private let roleField = AppKitText.field()
    private let agentPopup = AppKitText.popup()
    private let modelPopup = AppKitText.popup()
    private let maxIterField = AppKitText.field()
    private let instructionsView = NSTextView()
    private let artifactsField = AppKitText.field()
    private let routerNextButton = NSButton(checkboxWithTitle: "Requires router next.json", target: nil, action: nil)

    private let fromPopup = AppKitText.popup()
    private let typePopup = AppKitText.popup()
    private let toPopup = AppKitText.popup()
    private let targetsField = AppKitText.field()
    private let onPopup = AppKitText.popup()
    private let approvalButton = NSButton(checkboxWithTitle: "Requires approval", target: nil, action: nil)

    private let sectionLabel = AppKitText.label("Inspector", style: .title)
    private let emptyLabel = AppKitText.label("Select a node or edge on the canvas.", style: .muted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Theme.inspectorWidth).isActive = true

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)

        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configureTextView(goalView)
        configureTextView(instructionsView)
        goalView.delegate = self
        nameField.target = self
        nameField.action = #selector(projectFieldsChanged)
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)

        addSubview(border)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureTextView(_ view: NSTextView) {
        view.isRichText = false
        view.font = Theme.bodyFont()
        view.textColor = Theme.text
        view.backgroundColor = Theme.background
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
    }

    func reload(
        projectName: String,
        goal: String,
        org: OrgGraph,
        runners: RunnersConfig,
        selectedNodeId: String?,
        selectedEdgeId: String?
    ) {
        nodeIds = org.nodes.map(\.id)
        self.runners = runners
        currentNode = selectedNodeId.flatMap { org.node(id: $0) }
        currentEdge = org.edges.first { $0.id == selectedEdgeId }

        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        addStacked(sectionLabel)
        addStacked(FormField(title: "Project name", control: nameField))
        nameField.stringValue = projectName

        let goalScroll = wrapTextView(goalView, height: 70)
        addStacked(FormField(title: "Goal", control: goalScroll))
        if goalView.string != goal {
            goalView.string = goal
        }

        if let node = currentNode {
            addStacked(separator())
            addStacked(AppKitText.label("Node", style: .section))
            fillNodeFields(node)
            addStacked(FormField(title: "ID", control: nodeIdField))
            addStacked(FormField(title: "Role", control: roleField))
            addStacked(FormField(title: "Agent", control: agentPopup))
            addStacked(FormField(title: "Model", control: modelPopup))
            addStacked(FormField(title: "Max iterations", control: maxIterField))
            addStacked(FormField(title: "Instructions", control: wrapTextView(instructionsView, height: 100)))
            addStacked(FormField(title: "Done artifacts (comma-separated)", control: artifactsField))
            routerNextButton.target = self
            routerNextButton.action = #selector(applyNode)
            addStacked(routerNextButton)

            let apply = PrimaryButton(title: "Apply Node", style: .primary, target: self, action: #selector(applyNode))
            let entry = PrimaryButton(title: "Make Entry", style: .secondary, target: self, action: #selector(makeEntry))
            let del = PrimaryButton(title: "Delete", style: .danger, target: self, action: #selector(deleteNode))
            addStacked(buttonRow([apply, entry]))
            addStacked(del)
        } else if let edge = currentEdge {
            addStacked(separator())
            addStacked(AppKitText.label("Edge", style: .section))
            fillEdgeFields(edge)
            addStacked(FormField(title: "From", control: fromPopup))
            addStacked(FormField(title: "Type", control: typePopup))
            addStacked(FormField(title: "To", control: toPopup))
            addStacked(FormField(title: "Targets (comma-separated)", control: targetsField))
            addStacked(FormField(title: "On", control: onPopup))
            approvalButton.target = self
            approvalButton.action = #selector(applyEdge)
            addStacked(approvalButton)
            let apply = PrimaryButton(title: "Apply Edge", style: .primary, target: self, action: #selector(applyEdge))
            let del = PrimaryButton(title: "Delete", style: .danger, target: self, action: #selector(deleteEdge))
            addStacked(apply)
            addStacked(del)
            updateEdgeFieldVisibility()
        } else {
            addStacked(separator())
            addStacked(emptyLabel)
        }
    }

    /// Vertical stacks with `.leading` alignment keep intrinsic widths; pin to content width so fields fill.
    private func addStacked(_ view: NSView) {
        stack.addArrangedSubview(view)
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func fillNodeFields(_ node: OrgNode) {
        nodeIdField.stringValue = node.id
        nodeIdField.isEditable = false
        roleField.stringValue = node.role
        populateAgentPopup(selected: node.runner)
        let kind = selectedAgent()?.kind ?? .custom
        catalogModels = ModelCatalog.presets(for: kind)
        populateModelPopup(selected: node.model, agent: selectedAgent())
        loadCatalog(for: kind, selectedModel: node.model)
        maxIterField.stringValue = "\(node.maxIterations)"
        instructionsView.string = node.instructions
        let artifacts = node.done.checks.compactMap { check -> String? in
            if case .artifact(let p) = check { return p }
            return nil
        }
        artifactsField.stringValue = artifacts.joined(separator: ", ")
        routerNextButton.state = node.done.checks.contains {
            if case .routerNext = $0 { return true }
            return false
        } ? .on : .off
    }

    private func populateAgentPopup(selected: String) {
        agentPopup.removeAllItems()
        var names = runners.runners.keys.sorted()
        if !selected.isEmpty, !names.contains(selected) {
            names.insert(selected, at: 0)
        }
        if names.isEmpty {
            agentPopup.addItem(withTitle: selected.isEmpty ? "(no agents)" : selected)
            return
        }
        agentPopup.addItems(withTitles: names)
        agentPopup.selectItem(withTitle: selected)
    }

    private func selectedAgent() -> RunnerTemplate? {
        guard let name = agentPopup.titleOfSelectedItem else { return nil }
        return runners.agent(named: name)
    }

    @objc private func agentChanged() {
        let kind = selectedAgent()?.kind ?? .custom
        let selectedModel = selectedModelSlug()
        catalogModels = ModelCatalog.presets(for: kind)
        populateModelPopup(selected: selectedModel, agent: selectedAgent())
        loadCatalog(for: kind, selectedModel: selectedModel)
    }

    private func loadCatalog(for kind: AgentKind, selectedModel: String?) {
        catalogTask?.cancel()
        guard kind == .cursorAgent else { return }
        catalogTask = Task { [weak self] in
            let models = await ModelCatalog.models(for: .cursorAgent)
            await MainActor.run {
                guard let self else { return }
                self.catalogModels = models
                self.populateModelPopup(selected: selectedModel, agent: self.selectedAgent())
            }
        }
    }

    private func populateModelPopup(selected: String?, agent: RunnerTemplate?) {
        modelPopup.removeAllItems()
        guard let menu = modelPopup.menu else { return }

        let defaultLabel: String
        if let agentDefault = agent?.defaultModel, !agentDefault.isEmpty {
            defaultLabel = "(agent default: \(agentDefault))"
        } else {
            defaultLabel = "(agent default)"
        }
        let none = NSMenuItem(title: defaultLabel, action: nil, keyEquivalent: "")
        none.representedObject = "" as NSString
        menu.addItem(none)

        let kind = agent?.kind ?? .custom
        let models = ModelCatalog.merge(
            discovered: catalogModels.isEmpty ? ModelCatalog.presets(for: kind) : catalogModels,
            extras: [selected, agent?.defaultModel].compactMap { $0 }
        )
        for model in models {
            let item = NSMenuItem(title: model.menuTitle, action: nil, keyEquivalent: "")
            item.representedObject = model.slug as NSString
            item.toolTip = model.slug
            menu.addItem(item)
        }

        if let selected, !selected.isEmpty {
            if let idx = menu.items.firstIndex(where: { Self.representedString($0.representedObject) == selected }) {
                modelPopup.selectItem(at: idx)
            }
        } else {
            modelPopup.selectItem(at: 0)
        }
    }

    private func selectedModelSlug() -> String? {
        guard let slug = Self.representedString(modelPopup.selectedItem?.representedObject),
              !slug.isEmpty else { return nil }
        return slug
    }

    private static func representedString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return nil
    }

    private func fillEdgeFields(_ edge: OrgEdge) {
        fromPopup.removeAllItems()
        fromPopup.addItems(withTitles: nodeIds)
        fromPopup.selectItem(withTitle: edge.from)

        typePopup.removeAllItems()
        typePopup.addItems(withTitles: ["fixed", "router"])
        typePopup.selectItem(withTitle: edge.type.rawValue)
        typePopup.target = self
        typePopup.action = #selector(edgeTypeChanged)

        toPopup.removeAllItems()
        toPopup.addItems(withTitles: nodeIds)
        if let to = edge.to { toPopup.selectItem(withTitle: to) }

        targetsField.stringValue = edge.targets.joined(separator: ", ")
        onPopup.removeAllItems()
        onPopup.addItems(withTitles: ["always", "success", "fail", "reject"])
        onPopup.selectItem(withTitle: edge.on.rawValue)
        approvalButton.state = edge.requiresApproval ? .on : .off
    }

    @objc private func edgeTypeChanged() {
        updateEdgeFieldVisibility()
    }

    private func updateEdgeFieldVisibility() {
        let isRouter = typePopup.titleOfSelectedItem == "router"
        toPopup.superview?.isHidden = isRouter
        targetsField.superview?.isHidden = !isRouter
    }

    @objc private func projectFieldsChanged() {
        delegate?.orgInspector(self, didUpdateProjectName: nameField.stringValue)
    }

    @objc private func applyNode() {
        guard currentNode != nil else { return }
        let artifacts = artifactsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var checks: [DoneCheck] = artifacts.map { .artifact($0) }
        if routerNextButton.state == .on { checks.append(.routerNext) }
        let node = OrgNode(
            id: nodeIdField.stringValue,
            role: roleField.stringValue,
            runner: agentPopup.titleOfSelectedItem ?? currentNode?.runner ?? "",
            model: selectedModelSlug(),
            instructions: instructionsView.string,
            done: .allOf(checks),
            maxIterations: Int(maxIterField.stringValue) ?? 3
        )
        delegate?.orgInspector(self, didUpdateNode: node)
    }

    @objc private func makeEntry() {
        guard let id = currentNode?.id else { return }
        delegate?.orgInspector(self, didMakeEntry: id)
    }

    @objc private func deleteNode() {
        guard let id = currentNode?.id else { return }
        delegate?.orgInspector(self, didDeleteNode: id)
    }

    @objc private func applyEdge() {
        guard var edge = currentEdge else { return }
        edge.from = fromPopup.titleOfSelectedItem ?? edge.from
        edge.type = typePopup.titleOfSelectedItem == "router" ? .router : .fixed
        if edge.type == .fixed {
            edge.to = toPopup.titleOfSelectedItem
            edge.targets = []
        } else {
            edge.to = nil
            edge.targets = targetsField.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        edge.on = EdgeCondition(rawValue: onPopup.titleOfSelectedItem ?? "success") ?? .success
        edge.requiresApproval = approvalButton.state == .on
        delegate?.orgInspector(self, didUpdateEdge: edge)
    }

    @objc private func deleteEdge() {
        guard let id = currentEdge?.id else { return }
        delegate?.orgInspector(self, didDeleteEdge: id)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func buttonRow(_ buttons: [NSView]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func wrapTextView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.documentView = textView
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }
}

extension OrgInspectorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === goalView else { return }
        delegate?.orgInspector(self, didUpdateGoal: view.string)
    }
}
