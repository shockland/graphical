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

    override init() {
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor

        let title = AppKitText.label("Agents", style: .title)
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

        let listScroll = NSScrollView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.widthAnchor.constraint(equalToConstant: 200).isActive = true

        argsView.isRichText = false
        argsView.font = Theme.monoFont(ofSize: 12)
        let argsScroll = NSScrollView()
        argsScroll.translatesAutoresizingMaskIntoConstraints = false
        argsScroll.documentView = argsView
        argsScroll.hasVerticalScroller = true
        argsScroll.borderType = .bezelBorder
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

        let editor = NSStackView(views: [
            nameLabel,
            FormField(title: "Command", control: commandField),
            FormField(title: "Args (one per line)", control: argsScroll),
            FormField(title: "cwd", control: cwdField),
            FormField(title: "Kind", control: kindPopup),
            FormField(title: "Default model", control: defaultModelPopup),
            AppKitText.label(
                "Placeholders: {{project_root}} {{prompt_file}} {{node_artifacts}} {{run_id}} {{node_id}} {{model}}",
                style: .caption
            ),
            NSStackView(views: [apply, del]),
            NSBox(separator: ()),
            NSStackView(views: [newNameField, add])
        ])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 10
        editor.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [listScroll, editor])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            argsScroll.widthAnchor.constraint(equalToConstant: 420),
            commandField.widthAnchor.constraint(equalToConstant: 420),
            cwdField.widthAnchor.constraint(equalToConstant: 420),
            kindPopup.widthAnchor.constraint(equalToConstant: 420),
            defaultModelPopup.widthAnchor.constraint(equalToConstant: 420),
            newNameField.widthAnchor.constraint(equalToConstant: 220)
        ])
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
        loadDraft()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        names[row]
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < names.count else { return }
        selected = names[row]
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
        argsView.string = template.args.joined(separator: "\n")
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
        let args = argsView.string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        project.runners.runners[selected] = RunnerTemplate(
            command: commandField.stringValue,
            args: args,
            cwd: cwdField.stringValue,
            env: project.runners.runners[selected]?.env ?? [:],
            kind: selectedKind(),
            defaultModel: selectedDefaultModelSlug()
        )
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
        widthAnchor.constraint(equalToConstant: 420).isActive = true
    }
}
