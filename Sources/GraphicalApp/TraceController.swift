import AppKit
import GraphicalDomain

@MainActor
final class TraceController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: AppModel!
    let view = NSView()

    private let table = NSTableView()
    private let detail = NSTextView()
    private let header = AppKitText.label("Trace", style: .title)
    private let meta = AppKitText.label("", style: .muted)
    private var events: [TraceEvent] = []

    override init() {
        super.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor

        let export = PrimaryButton(title: "Export JSON", style: .secondary, target: self, action: #selector(exportJSON))
        let top = NSStackView(views: [header, meta, NSView(), export])
        top.orientation = .horizontal
        top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("event"))
        col.title = "Events"
        col.width = 280
        table.addTableColumn(col)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 52
        table.backgroundColor = Theme.surface
        table.selectionHighlightStyle = .regular

        let listScroll = NSScrollView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder

        detail.isEditable = false
        detail.isRichText = false
        detail.font = Theme.monoFont(ofSize: 12)
        detail.textColor = Theme.text
        detail.backgroundColor = Theme.surface
        detail.textContainerInset = NSSize(width: 12, height: 12)

        let detailScroll = NSScrollView()
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder

        view.addSubview(top)
        view.addSubview(listScroll)
        view.addSubview(detailScroll)

        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),

            listScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            listScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            listScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            listScroll.widthAnchor.constraint(equalToConstant: 320),

            detailScroll.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 12),
            detailScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            detailScroll.topAnchor.constraint(equalTo: listScroll.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor)
        ])
    }

    func reload() {
        events = model.events
        if let run = model.run {
            meta.stringValue = "Run \(run.id) · \(run.status.rawValue)"
        } else {
            meta.stringValue = "No run loaded"
        }
        table.reloadData()
        if table.selectedRow < 0, !events.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(events[0])
        } else if table.selectedRow >= 0, table.selectedRow < events.count {
            showDetail(events[table.selectedRow])
        } else {
            detail.string = "Select an event"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let event = events[row]
        let cell = NSTableCellView()
        let title = AppKitText.label(event.kind.rawValue, style: .section)
        let message = AppKitText.label(event.message, style: .caption)
        message.textColor = Theme.muted
        message.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < events.count else { return }
        showDetail(events[row])
    }

    private func showDetail(_ event: TraceEvent) {
        var text = "\(event.kind.rawValue)\n\n\(event.message)\n"
        if let nodeId = event.nodeId { text += "\nNode: \(nodeId)" }
        if let iteration = event.iteration { text += "\nIteration: \(iteration)" }
        if let payload = event.payloadJSON, !payload.isEmpty {
            text += "\n\nPayload\n\(payload)"
        } else {
            text += "\n\nNo payload"
        }
        detail.string = text
    }

    @objc private func exportJSON() { model.exportTrace() }
}
