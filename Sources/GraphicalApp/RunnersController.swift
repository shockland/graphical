import AppKit
import GraphicalDomain
import GraphicalCLI

@MainActor
final class RunnersController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: AppModel!
    let view = NSView()

    private let table = NSTableView()
    private var names: [String] = []
    private var selected: String?
    private var catalogModels: [CatalogModel] = []
    private var catalogTask: Task<Void, Never>?

    private let nameLabel = AppKitText.label("Select an agent", style: .title)
    private let commandField = AppKitText.field()
    private let argsView = NSTextView()
    private let cwdField = AppKitText.field()
    private let kindPopup = AppKitText.popup()
    private let defaultModelPopup = AppKitText.popup()
    private let newNameField = AppKitText.field()
    private let listEmpty = TabEmptyStateView(
        icon: "person.crop.circle.badge.plus",
        title: "No agents yet",
        detail: "Add a coding-tool agent below, or use Set up coding tool to apply a preset."
    )
    private let editorEmpty = TabEmptyStateView(
        icon: "person.crop.circle",
        title: "Select an agent",
        detail: "Choose an agent from the list to edit its command, args, and default model."
    )
    private var editorFormViews: [NSView] = []
    private var editorAddSectionViews: [NSView] = []

    override init() {
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor

        let title = AppKitText.label("Agents", style: .title)
        let setupToolButton = PrimaryButton(
            title: "Set up coding tool…",
            style: .secondary,
            target: self,
            action: #selector(requestCodingToolSetup)
        )
        setupToolButton.setAccessibilityLabel("Set up coding tool")
        let titleRow = NSStackView(views: [title, NSView(), setupToolButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = AppKitText.label(
            "CLI agents with a kind and default model. Nodes bind to an agent by name.",
            style: .muted
        )

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Agents"
        table.addTableColumn(col)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28
        table.backgroundColor = Theme.surface

        let listScroll = ThemedScrollView()
        listScroll.documentView = table
        listScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let listPane = NSView()
        listPane.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(listScroll)
        listPane.addSubview(listEmpty)
        listEmpty.isHidden = true

        argsView.isRichText = false
        argsView.font = Theme.monoFont(ofSize: 12)
        let argsScroll = ThemedScrollView()
        argsScroll.documentView = argsView
        argsScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        kindPopup.removeAllItems()
        for kind in AgentKind.allCases {
            kindPopup.addItem(withTitle: kind.displayName)
            kindPopup.lastItem?.representedObject = kind.rawValue as NSString
        }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)

        let apply = PrimaryButton(title: "Apply", style: .primary, target: self, action: #selector(applyDraft))
        let del = PrimaryButton(title: "Delete", style: .danger, target: self, action: #selector(deleteRunner))
        let add = PrimaryButton(title: "Add", style: .secondary, target: self, action: #selector(addRunner))

        let applyRow = NSStackView(views: [apply, del])
        let addRow = NSStackView(views: [newNameField, add])
        let placeholders = AppKitText.label(
            "Placeholders: {{project_root}} {{prompt_file}} {{node_artifacts}} {{run_id}} {{node_id}} {{model}}",
            style: .caption
        )
        editorFormViews = [
            FormField(title: "Command", control: commandField),
            FormField(title: "Args (one per line; YAML list if multiline)", control: argsScroll),
            FormField(title: "cwd", control: cwdField),
            FormField(title: "Kind", control: kindPopup),
            FormField(title: "Default model", control: defaultModelPopup),
            placeholders,
            applyRow
        ]
        editorAddSectionViews = [NSBox(separator: ()), addRow]

        let editor = NSStackView(views: [nameLabel, editorEmpty] + editorFormViews + editorAddSectionViews)
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 10
        editor.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [listPane, editor])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false
        editorEmpty.isHidden = true

        let stack = NSStackView(views: [titleRow, subtitle, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = stack
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -16),

            listPane.widthAnchor.constraint(equalToConstant: 180),
            listPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            listScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: listPane.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            listEmpty.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listEmpty.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listEmpty.topAnchor.constraint(equalTo: listPane.topAnchor),
            listEmpty.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            editorEmpty.widthAnchor.constraint(equalTo: editor.widthAnchor),
            argsScroll.widthAnchor.constraint(equalTo: editor.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: editor.widthAnchor),
            cwdField.widthAnchor.constraint(equalTo: editor.widthAnchor),
            kindPopup.widthAnchor.constraint(equalTo: editor.widthAnchor),
            defaultModelPopup.widthAnchor.constraint(equalTo: editor.widthAnchor),
            newNameField.widthAnchor.constraint(equalToConstant: 180)
        ])
        let editorMinWidth = editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        editorMinWidth.priority = .defaultLow
        editorMinWidth.isActive = true
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func reload() {
        names = model.project?.runners.runners.keys.sorted() ?? []
        if selected == nil || !(names.contains(selected ?? "")) {
            selected = names.first
        }
        table.reloadData()
        if let selected, let idx = names.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        updateEmptyStates()
        loadDraft()
    }

    private func updateEmptyStates() {
        listEmpty.isHidden = !names.isEmpty
        let editing = selected != nil && names.contains(selected ?? "")
        editorEmpty.isHidden = editing || names.isEmpty
        nameLabel.isHidden = !editing
        for view in editorFormViews {
            view.isHidden = !editing
        }
        for view in editorAddSectionViews {
            view.isHidden = false
        }
    }

    @objc private func requestCodingToolSetup() {
        model.requestCodingToolSetup()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        names[row]
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < names.count else {
            selected = nil
            updateEmptyStates()
            loadDraft()
            return
        }
        selected = names[row]
        updateEmptyStates()
        loadDraft()
    }

    private func loadDraft() {
        guard let selected, let template = model.project?.runners.runners[selected] else {
            nameLabel.stringValue = "Select an agent"
            commandField.stringValue = ""
            argsView.string = ""
            cwdField.stringValue = "{{project_root}}"
            selectKind(.custom)
            refreshDefaultModelPopup(selected: nil, kind: .custom)
            return
        }
        nameLabel.stringValue = selected
        commandField.stringValue = template.command
        argsView.string = RunnerArgsEditing.encodeForEditor(template.args)
        cwdField.stringValue = template.cwd ?? "{{project_root}}"
        selectKind(template.kind)
        refreshDefaultModelPopup(selected: template.defaultModel, kind: template.kind)
        loadCatalog(for: template.kind, selectedDefault: template.defaultModel)
    }

    private func selectKind(_ kind: AgentKind) {
        if let idx = kindPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == kind.rawValue
                || ($0.representedObject as? NSString) as String? == kind.rawValue
        }) {
            kindPopup.selectItem(at: idx)
        }
    }

    private func selectedKind() -> AgentKind {
        let raw = (kindPopup.selectedItem?.representedObject as? String)
            ?? (kindPopup.selectedItem?.representedObject as? NSString) as String?
        return AgentKind(rawValue: raw ?? "") ?? .custom
    }

    @objc private func kindChanged() {
        let kind = selectedKind()
        let current = selectedDefaultModelSlug()
        refreshDefaultModelPopup(selected: current, kind: kind)
        loadCatalog(for: kind, selectedDefault: current)
    }

    private func loadCatalog(for kind: AgentKind, selectedDefault: String?) {
        catalogTask?.cancel()
        catalogModels = ModelCatalog.presets(for: kind)
        refreshDefaultModelPopup(selected: selectedDefault, kind: kind)
        guard kind == .cursorAgent else { return }
        catalogTask = Task { [weak self] in
            let models = await ModelCatalog.models(for: .cursorAgent)
            guard let self, !Task.isCancelled else { return }
            self.catalogModels = models
            self.refreshDefaultModelPopup(selected: selectedDefault, kind: .cursorAgent)
        }
    }

    private func refreshDefaultModelPopup(selected: String?, kind: AgentKind) {
        defaultModelPopup.removeAllItems()
        guard let menu = defaultModelPopup.menu else { return }

        let none = NSMenuItem(title: "(CLI default)", action: nil, keyEquivalent: "")
        none.representedObject = "" as NSString
        menu.addItem(none)

        let models = ModelCatalog.merge(
            discovered: catalogModels.isEmpty ? ModelCatalog.presets(for: kind) : catalogModels,
            extras: [selected].compactMap { $0 }
        )
        for model in models {
            let item = NSMenuItem(title: model.menuTitle, action: nil, keyEquivalent: "")
            item.representedObject = model.slug as NSString
            item.toolTip = model.slug
            menu.addItem(item)
        }

        if let selected, !selected.isEmpty,
           let idx = menu.items.firstIndex(where: { Self.representedString($0.representedObject) == selected }) {
            defaultModelPopup.selectItem(at: idx)
        } else {
            defaultModelPopup.selectItem(at: 0)
        }
    }

    private func selectedDefaultModelSlug() -> String? {
        guard let slug = Self.representedString(defaultModelPopup.selectedItem?.representedObject),
              !slug.isEmpty else { return nil }
        return slug
    }

    private static func representedString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return nil
    }

    @objc private func applyDraft() {
        guard let selected, var project = model.project else { return }
        let template = RunnerArgsEditing.repairingShreddedShellScript(
            RunnerTemplate(
                command: commandField.stringValue,
                args: RunnerArgsEditing.decodeFromEditor(argsView.string),
                cwd: cwdField.stringValue,
                env: project.runners.runners[selected]?.env ?? [:],
                kind: selectedKind(),
                defaultModel: selectedDefaultModelSlug()
            )
        )
        project.runners.runners[selected] = template
        model.updateRunners(project.runners)
        model.saveProject()
    }

    @objc private func addRunner() {
        let name = newNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var project = model.project else { return }
        project.runners.runners[name] = RunnerTemplate(
            command: "claude",
            args: ["-p", "{{prompt_file}}", "--model", "{{model}}"],
            cwd: "{{project_root}}",
            kind: .claudeCode,
            defaultModel: "sonnet"
        )
        model.updateRunners(project.runners)
        newNameField.stringValue = ""
        selected = name
        reload()
    }

    @objc private func deleteRunner() {
        guard let selected, var project = model.project else { return }
        guard ConfirmDialog.confirmDelete(
            title: "Delete agent?",
            message: "Remove “\(selected)” from this project? Steps using this agent will need a new binding."
        ) else { return }
        project.runners.runners.removeValue(forKey: selected)
        model.updateRunners(project.runners)
        self.selected = nil
        reload()
    }
}

private extension NSBox {
    convenience init(separator: ()) {
        self.init(frame: .zero)
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
    }
}
