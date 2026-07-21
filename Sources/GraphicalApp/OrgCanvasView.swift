import AppKit
import GraphicalDomain

@MainActor
protocol OrgCanvasViewDelegate: AnyObject {
    func orgCanvasDidChangeSelection(_ canvas: OrgCanvasView)
    func orgCanvas(_ canvas: OrgCanvasView, didMoveNode id: String, to point: CGPoint, ended: Bool)
    func orgCanvasDidRequestAddNode(_ canvas: OrgCanvasView)
    func orgCanvas(_ canvas: OrgCanvasView, didCreateEdgeFrom: String, to: String, router: Bool)
    func orgCanvasDidRequestDeleteSelection(_ canvas: OrgCanvasView)
    func orgCanvasDidRequestCancelConnect(_ canvas: OrgCanvasView)
}

enum OrgCanvasTool {
    case select
    case connectFixed
    case connectRouter
}

final class OrgCanvasView: NSView {
    weak var delegate: OrgCanvasViewDelegate?

    private(set) var org = OrgGraph()
    private(set) var layout = CanvasLayout()
    private(set) var selectedNodeId: String?
    private(set) var selectedEdgeId: String?
    private(set) var activeRunNodeId: String?
    private var runPaused = false
    var tool: OrgCanvasTool = .select
    private var connectFromId: String?

    private var scale: CGFloat = 1
    private var offset: CGPoint = .zero
    private var dragNodeId: String?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartNode: CGPoint = .zero
    private var isPanning = false
    private var panStartMouse: CGPoint = .zero
    private var panStartOffset: CGPoint = .zero
    private var selectionPulse: CGFloat = 0
    private var runPulse: CGFloat = 0
    private var pulseTimer: Timer?
    private var runPulseTimer: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        org: OrgGraph,
        layout: CanvasLayout,
        selectedNodeId: String?,
        selectedEdgeId: String?,
        activeRunNodeId: String? = nil,
        runPaused: Bool = false
    ) {
        self.org = org
        self.layout = layout
        self.selectedNodeId = selectedNodeId
        self.selectedEdgeId = selectedEdgeId
        setActiveRunHighlight(nodeId: activeRunNodeId, paused: runPaused)
        needsDisplay = true
        if selectedNodeId != nil || selectedEdgeId != nil {
            startSelectionPulse()
        }
    }

    func setActiveRunHighlight(nodeId: String?, paused: Bool) {
        guard activeRunNodeId != nodeId || runPaused != paused else { return }
        activeRunNodeId = nodeId
        runPaused = paused
        if nodeId != nil {
            startRunPulse()
        } else {
            stopRunPulse()
        }
        needsDisplay = true
    }

    func setTool(_ tool: OrgCanvasTool) {
        self.tool = tool
        connectFromId = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func select(nodeId: String?, edgeId: String?) {
        selectedNodeId = nodeId
        selectedEdgeId = edgeId
        if nodeId != nil || edgeId != nil {
            startSelectionPulse()
        }
        needsDisplay = true
    }

    func fitToContent() {
        guard !layout.nodes.isEmpty else {
            resetZoom()
            return
        }
        var contentBounds = CGRect.null
        for node in org.nodes {
            guard let pos = layout.nodes[node.id] else { continue }
            contentBounds = contentBounds.union(nodeRect(node, pos: pos))
        }
        let padding: CGFloat = 48
        contentBounds = contentBounds.insetBy(dx: -padding, dy: -padding)
        guard contentBounds.width > 0, contentBounds.height > 0, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let scaleX = bounds.width / contentBounds.width
        let scaleY = bounds.height / contentBounds.height
        scale = min(2.2, max(0.45, min(scaleX, scaleY)))
        offset = CGPoint(
            x: (bounds.width - contentBounds.width * scale) / 2 - contentBounds.minX * scale,
            y: (bounds.height - contentBounds.height * scale) / 2 - contentBounds.minY * scale
        )
        needsDisplay = true
    }

    func resetZoom() {
        scale = 1
        offset = .zero
        needsDisplay = true
    }

    func centerOn(nodeId: String) {
        guard let pos = layout.nodes[nodeId],
              let node = org.node(id: nodeId) else { return }
        let rect = nodeRect(node, pos: pos)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        offset = CGPoint(
            x: bounds.width / 2 - center.x * scale,
            y: bounds.height / 2 - center.y * scale
        )
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            if selectedNodeId != nil || selectedEdgeId != nil {
                delegate?.orgCanvasDidRequestDeleteSelection(self)
            }
        case 53: // Escape
            if tool != .select || connectFromId != nil {
                setTool(.select)
                delegate?.orgCanvasDidRequestCancelConnect(self)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
        drawGrid()

        let transform = CGAffineTransform(translationX: offset.x, y: offset.y)
            .scaledBy(x: scale, y: scale)
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.concatenate(transform)

        for edge in org.edges {
            drawEdge(edge)
        }
        for node in org.nodes {
            drawNode(node)
        }

        if let from = connectFromId,
           let pos = layout.nodes[from],
           let node = org.node(id: from) {
            let start = nodeCenter(node, pos: pos)
            let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let end = viewToCanvas(mouse)
            Theme.accent.withAlphaComponent(0.5).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: start)
            path.line(to: end)
            path.stroke()
        }

        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func drawGrid() {
        let step: CGFloat = 24
        let dotRadius: CGFloat = 0.75
        Theme.border.withAlphaComponent(0.65).setFill()
        var x: CGFloat = step / 2
        while x < bounds.width {
            var y: CGFloat = step / 2
            while y < bounds.height {
                let dot = NSBezierPath(ovalIn: NSRect(
                    x: x - dotRadius,
                    y: y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
                dot.fill()
                y += step
            }
            x += step
        }
    }

    private struct NodeMetrics {
        let size: CGSize
        let isEntry: Bool
        let startRow: CGRect?
        let roleRect: CGRect
        let metaRect: CGRect
        let chipRect: CGRect
        let badgeRect: CGRect?
        let entryBarRect: CGRect?
    }

    private func isEntryNode(_ node: OrgNode) -> Bool {
        org.entry == node.id || (org.entry == nil && org.nodes.first?.id == node.id)
    }

    private func nodeMetrics(for node: OrgNode) -> NodeMetrics {
        let isEntry = isEntryNode(node)
        let isActiveRun = activeRunNodeId == node.id

        let roleFont = Theme.bodyFont(ofSize: Theme.nodeRoleFontSize, weight: .semibold)
        let metaFont = Theme.monoFont(ofSize: Theme.nodeMetaFontSize)
        let chipFont = Theme.bodyFont(ofSize: Theme.nodeChipFontSize, weight: .medium)
        let badgeFont = Theme.bodyFont(ofSize: Theme.nodeBadgeFontSize, weight: .semibold)
        let startFont = Theme.bodyFont(ofSize: Theme.nodeStartFontSize, weight: .bold)

        let roleLineHeight = ceil(roleFont.ascender - roleFont.descender + 2)
        let metaLineHeight = ceil(metaFont.ascender - metaFont.descender + 2)
        let startRowHeight = ceil(startFont.ascender - startFont.descender + 2)

        let chipText = node.model ?? "—"
        let chipTextSize = (chipText as NSString).size(withAttributes: [.font: chipFont])
        let chipSize = CGSize(
            width: chipTextSize.width + Theme.nodeChipPaddingH * 2,
            height: chipTextSize.height + Theme.nodeChipPaddingV * 2
        )

        var badgeSize = CGSize.zero
        if isActiveRun {
            let badgeLabel = runPaused ? "Paused" : "Working"
            let textSize = (badgeLabel as NSString).size(withAttributes: [.font: badgeFont])
            badgeSize = CGSize(
                width: textSize.width + Theme.nodeBadgePaddingH * 2,
                height: textSize.height + Theme.nodeBadgePaddingV * 2
            )
        }

        let metaText = "\(node.id) · \(node.runner)"
        let innerMaxWidth = Theme.nodeMaxWidth - Theme.nodeContentInsetLeft - Theme.nodePaddingH

        let metaWidth = min(
            innerMaxWidth,
            (metaText as NSString).size(withAttributes: [.font: metaFont]).width
        )
        let roleNaturalWidth = (node.role as NSString).size(withAttributes: [.font: roleFont]).width
        let roleWidthWithBadge = innerMaxWidth - (badgeSize.width > 0 ? badgeSize.width + Theme.spacingXS : 0)
        let roleWidth = min(roleWidthWithBadge, roleNaturalWidth)

        let width = max(
            Theme.nodeMinWidth,
            min(
                Theme.nodeMaxWidth,
                max(roleWidth, metaWidth, chipSize.width) + Theme.nodeContentInsetLeft + Theme.nodePaddingH
            )
        )

        let contentRight = width - Theme.nodePaddingH
        let contentLeft = Theme.nodeContentInsetLeft

        var y = Theme.nodePaddingV
        let roleRowY = isEntry ? y + startRowHeight + Theme.nodeRowSpacing : y
        var startRow: CGRect?
        if isEntry {
            let startWidth = badgeSize.width > 0
                ? max(0, contentRight - badgeSize.width - Theme.spacingXS - contentLeft)
                : contentRight - contentLeft
            startRow = CGRect(
                x: contentLeft,
                y: y,
                width: startWidth,
                height: startRowHeight
            )
            y = roleRowY
        }

        let badgeRect: CGRect?
        if badgeSize.width > 0 {
            badgeRect = CGRect(
                x: contentRight - badgeSize.width,
                y: roleRowY,
                width: badgeSize.width,
                height: badgeSize.height
            )
        } else {
            badgeRect = nil
        }

        let roleWidthAvailable: CGFloat
        if let badge = badgeRect {
            roleWidthAvailable = max(0, badge.minX - contentLeft - Theme.spacingXS)
        } else {
            roleWidthAvailable = contentRight - contentLeft
        }
        let roleRect = CGRect(
            x: contentLeft,
            y: y,
            width: roleWidthAvailable,
            height: roleLineHeight
        )
        y += roleLineHeight + Theme.nodeRowSpacing

        let metaRect = CGRect(
            x: contentLeft,
            y: y,
            width: contentRight - contentLeft,
            height: metaLineHeight
        )
        y += metaLineHeight + Theme.nodeRowSpacing

        let chipRect = CGRect(
            x: contentLeft,
            y: y,
            width: min(chipSize.width, contentRight - contentLeft),
            height: chipSize.height
        )
        y += chipSize.height

        y += Theme.nodePaddingV
        let height = max(Theme.nodeMinHeight, y)

        let entryBarRect: CGRect? = isEntry
            ? CGRect(
                x: 0,
                y: Theme.nodePaddingV,
                width: Theme.nodeEntryBarWidth,
                height: height - Theme.nodePaddingV * 2
            )
            : nil

        return NodeMetrics(
            size: CGSize(width: width, height: height),
            isEntry: isEntry,
            startRow: startRow,
            roleRect: roleRect,
            metaRect: metaRect,
            chipRect: chipRect,
            badgeRect: badgeRect,
            entryBarRect: entryBarRect
        )
    }

    private func nodeSize(for node: OrgNode) -> CGSize {
        nodeMetrics(for: node).size
    }

    private func drawTruncatedText(
        _ text: String,
        in rect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .left
        var attrs = attributes
        attrs[.paragraphStyle] = style
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private func drawNode(_ node: OrgNode) {
        guard let pos = layout.nodes[node.id] else { return }
        let metrics = nodeMetrics(for: node)
        let rect = CGRect(origin: CGPoint(x: pos.x, y: pos.y), size: metrics.size)
        let selected = selectedNodeId == node.id
        let isActiveRun = activeRunNodeId == node.id

        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)

        NSGraphicsContext.current?.saveGraphicsState()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setShadow(
                offset: Theme.nodeShadowOffset,
                blur: Theme.nodeShadowRadius,
                color: NSColor.black.withAlphaComponent(Theme.nodeShadowOpacity).cgColor
            )
        }
        if isActiveRun {
            Theme.accentSoft.withAlphaComponent(0.45 + 0.35 * runPulse).setFill()
        } else {
            Theme.surface.setFill()
        }
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        if isActiveRun {
            Theme.accent.withAlphaComponent(0.55 + 0.35 * runPulse).setStroke()
            path.lineWidth = 2.75
        } else if selected {
            Theme.accent.withAlphaComponent(0.35 + 0.25 * selectionPulse).setStroke()
            path.lineWidth = 2.5
        } else {
            Theme.border.setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        if let bar = metrics.entryBarRect {
            let barPath = NSBezierPath(
                roundedRect: bar.offsetBy(dx: rect.minX, dy: rect.minY),
                xRadius: 2.5,
                yRadius: 2.5
            )
            Theme.accent.setFill()
            barPath.fill()
        }

        if let startRow = metrics.startRow {
            drawTruncatedText(
                "START",
                in: startRow.offsetBy(dx: rect.minX, dy: rect.minY),
                attributes: [
                    .font: Theme.bodyFont(ofSize: Theme.nodeStartFontSize, weight: .bold),
                    .foregroundColor: Theme.accent
                ]
            )
        }

        drawTruncatedText(
            node.role,
            in: metrics.roleRect.offsetBy(dx: rect.minX, dy: rect.minY),
            attributes: [
                .font: Theme.bodyFont(ofSize: Theme.nodeRoleFontSize, weight: .semibold),
                .foregroundColor: Theme.text
            ]
        )

        drawTruncatedText(
            "\(node.id) · \(node.runner)",
            in: metrics.metaRect.offsetBy(dx: rect.minX, dy: rect.minY),
            attributes: [
                .font: Theme.monoFont(ofSize: Theme.nodeMetaFontSize),
                .foregroundColor: Theme.muted
            ]
        )

        let chipRect = metrics.chipRect
        let absoluteChip = chipRect.offsetBy(dx: rect.minX, dy: rect.minY)
        let chipPath = NSBezierPath(
            roundedRect: absoluteChip,
            xRadius: Theme.nodeChipCornerRadius,
            yRadius: Theme.nodeChipCornerRadius
        )
        Theme.accentSoft.setFill()
        chipPath.fill()
        drawTruncatedText(
            node.model ?? "—",
            in: NSRect(
                x: absoluteChip.minX + Theme.nodeChipPaddingH,
                y: absoluteChip.minY + Theme.nodeChipPaddingV,
                width: absoluteChip.width - Theme.nodeChipPaddingH * 2,
                height: absoluteChip.height - Theme.nodeChipPaddingV * 2
            ),
            attributes: [
                .font: Theme.bodyFont(ofSize: Theme.nodeChipFontSize, weight: .medium),
                .foregroundColor: Theme.accent
            ]
        )

        if let badgeRect = metrics.badgeRect {
            let absoluteBadge = badgeRect.offsetBy(dx: rect.minX, dy: rect.minY)
            let label = runPaused ? "Paused" : "Working"
            let font = Theme.bodyFont(ofSize: Theme.nodeBadgeFontSize, weight: .semibold)
            let badgePath = NSBezierPath(
                roundedRect: absoluteBadge,
                xRadius: Theme.nodeBadgeCornerRadius,
                yRadius: Theme.nodeBadgeCornerRadius
            )
            Theme.accentSoft.setFill()
            badgePath.fill()
            drawTruncatedText(
                label,
                in: NSRect(
                    x: absoluteBadge.minX + Theme.nodeBadgePaddingH,
                    y: absoluteBadge.minY + Theme.nodeBadgePaddingV,
                    width: absoluteBadge.width - Theme.nodeBadgePaddingH * 2,
                    height: absoluteBadge.height - Theme.nodeBadgePaddingV * 2
                ),
                attributes: [
                    .font: font,
                    .foregroundColor: Theme.accent
                ]
            )
        }
    }

    private func drawEdge(_ edge: OrgEdge) {
        guard let fromNode = org.node(id: edge.from),
              let fromPos = layout.nodes[edge.from] else { return }
        let from = nodeCenter(fromNode, pos: fromPos)
        let selected = selectedEdgeId == edge.id

        let destinations: [CGPoint]
        switch edge.type {
        case .fixed:
            guard let toId = edge.to,
                  let toNode = org.node(id: toId),
                  let toPos = layout.nodes[toId] else { return }
            destinations = [nodeCenter(toNode, pos: toPos)]
        case .router:
            destinations = edge.targets.compactMap { id in
                guard let node = org.node(id: id), let pos = layout.nodes[id] else { return nil }
                return nodeCenter(node, pos: pos)
            }
        }

        for (index, to) in destinations.enumerated() {
            let path = bezier(from: from, to: to)
            if edge.type == .router {
                let dashes: [CGFloat] = [6, 4]
                path.setLineDash(dashes, count: 2, phase: 0)
            }
            path.lineWidth = selected ? 2.25 : 1.5
            (selected ? Theme.accent : Theme.muted.withAlphaComponent(0.75)).setStroke()
            path.stroke()
            drawArrowhead(from: from, to: to, color: selected ? Theme.accent : Theme.muted)

            if edge.requiresApproval, index == 0 {
                let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 8)
                let gate = NSBezierPath(
                    roundedRect: NSRect(x: mid.x - 8, y: mid.y - 8, width: 16, height: 16),
                    xRadius: 3,
                    yRadius: 3
                )
                Theme.surface.setFill()
                Theme.warning.setStroke()
                gate.lineWidth = 1.5
                gate.fill()
                gate.stroke()
            }
        }
    }

    private func bezier(from: CGPoint, to: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        let dx = max(40, abs(to.x - from.x) * 0.45)
        path.move(to: from)
        path.curve(
            to: to,
            controlPoint1: CGPoint(x: from.x + dx, y: from.y),
            controlPoint2: CGPoint(x: to.x - dx, y: to.y)
        )
        return path
    }

    private func drawArrowhead(from: CGPoint, to: CGPoint, color: NSColor) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let size: CGFloat = 8
        let path = NSBezierPath()
        path.move(to: to)
        path.line(to: CGPoint(
            x: to.x - size * cos(angle - .pi / 7),
            y: to.y - size * sin(angle - .pi / 7)
        ))
        path.line(to: CGPoint(
            x: to.x - size * cos(angle + .pi / 7),
            y: to.y - size * sin(angle + .pi / 7)
        ))
        path.close()
        color.setFill()
        path.fill()
    }

    // MARK: - Geometry

    private func nodeRect(_ node: OrgNode, pos: NodePosition) -> CGRect {
        let size = nodeSize(for: node)
        return CGRect(x: pos.x, y: pos.y, width: size.width, height: size.height)
    }

    private func nodeCenter(_ node: OrgNode, pos: NodePosition) -> CGPoint {
        let size = nodeSize(for: node)
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    private func viewToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    private func hitNode(at canvasPoint: CGPoint) -> String? {
        for node in org.nodes.reversed() {
            guard let pos = layout.nodes[node.id] else { continue }
            if nodeRect(node, pos: pos).contains(canvasPoint) {
                return node.id
            }
        }
        return nil
    }

    private func hitEdge(at canvasPoint: CGPoint) -> String? {
        for edge in org.edges {
            guard let fromNode = org.node(id: edge.from),
                  let fromPos = layout.nodes[edge.from] else { continue }
            let from = nodeCenter(fromNode, pos: fromPos)
            let tos: [CGPoint]
            switch edge.type {
            case .fixed:
                guard let toId = edge.to,
                      let toNode = org.node(id: toId),
                      let toPos = layout.nodes[toId] else { continue }
                tos = [nodeCenter(toNode, pos: toPos)]
            case .router:
                tos = edge.targets.compactMap { id in
                    guard let node = org.node(id: id), let pos = layout.nodes[id] else { return nil }
                    return nodeCenter(node, pos: pos)
                }
            }
            for to in tos {
                if distanceToBezier(point: canvasPoint, from: from, to: to) < 8 {
                    return edge.id
                }
            }
        }
        return nil
    }

    private func distanceToBezier(point: CGPoint, from: CGPoint, to: CGPoint) -> CGFloat {
        // Sample cubic for hit testing
        let dx = max(40, abs(to.x - from.x) * 0.45)
        let c1 = CGPoint(x: from.x + dx, y: from.y)
        let c2 = CGPoint(x: to.x - dx, y: to.y)
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0...20 {
            let t = CGFloat(i) / 20
            let mt = 1 - t
            let x = mt * mt * mt * from.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * to.x
            let y = mt * mt * mt * from.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * to.y
            let d = hypot(point.x - x, point.y - y)
            best = min(best, d)
        }
        return best
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = viewToCanvas(viewPoint)

        if event.modifierFlags.contains(.option) || tool == .select && event.clickCount == 0 && false {
            // unused
        }

        if event.modifierFlags.contains(.command) {
            isPanning = true
            panStartMouse = viewPoint
            panStartOffset = offset
            return
        }

        if let nodeId = hitNode(at: canvasPoint) {
            switch tool {
            case .select:
                selectedNodeId = nodeId
                selectedEdgeId = nil
                dragNodeId = nodeId
                dragStartMouse = canvasPoint
                if let pos = layout.nodes[nodeId] {
                    dragStartNode = CGPoint(x: pos.x, y: pos.y)
                }
                startSelectionPulse()
                delegate?.orgCanvasDidChangeSelection(self)
                needsDisplay = true
            case .connectFixed, .connectRouter:
                if let from = connectFromId {
                    if from != nodeId {
                        delegate?.orgCanvas(
                            self,
                            didCreateEdgeFrom: from,
                            to: nodeId,
                            router: tool == .connectRouter
                        )
                    }
                    connectFromId = nil
                    tool = .select
                } else {
                    connectFromId = nodeId
                }
                needsDisplay = true
            }
            return
        }

        if tool == .select, let edgeId = hitEdge(at: canvasPoint) {
            selectedEdgeId = edgeId
            selectedNodeId = nil
            startSelectionPulse()
            delegate?.orgCanvasDidChangeSelection(self)
            needsDisplay = true
            return
        }

        selectedNodeId = nil
        selectedEdgeId = nil
        connectFromId = nil
        delegate?.orgCanvasDidChangeSelection(self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isPanning {
            offset = CGPoint(
                x: panStartOffset.x + (viewPoint.x - panStartMouse.x),
                y: panStartOffset.y + (viewPoint.y - panStartMouse.y)
            )
            needsDisplay = true
            return
        }
        guard let dragNodeId, let _ = layout.nodes[dragNodeId] else {
            if connectFromId != nil { needsDisplay = true }
            return
        }
        let canvasPoint = viewToCanvas(viewPoint)
        let dx = canvasPoint.x - dragStartMouse.x
        let dy = canvasPoint.y - dragStartMouse.y
        let newPoint = CGPoint(x: dragStartNode.x + dx, y: dragStartNode.y + dy)
        layout.nodes[dragNodeId] = NodePosition(x: newPoint.x, y: newPoint.y)
        delegate?.orgCanvas(self, didMoveNode: dragNodeId, to: newPoint, ended: false)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let dragNodeId, let pos = layout.nodes[dragNodeId] {
            delegate?.orgCanvas(
                self,
                didMoveNode: dragNodeId,
                to: CGPoint(x: pos.x, y: pos.y),
                ended: true
            )
        }
        dragNodeId = nil
        isPanning = false
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = event.deltaY > 0 ? 1.05 : 0.95
            scale = min(2.2, max(0.45, scale * factor))
            needsDisplay = true
        } else {
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        scale = min(2.2, max(0.45, scale * (1 + event.magnification)))
        needsDisplay = true
    }

    private func startSelectionPulse() {
        pulseTimer?.invalidate()
        selectionPulse = 0
        var rising = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            selectionPulse += rising ? 0.08 : -0.08
            if selectionPulse >= 1 { rising = false }
            if selectionPulse <= 0 {
                rising = true
                timer.invalidate()
                self.pulseTimer = nil
            }
            self.needsDisplay = true
        }
    }

    private func startRunPulse() {
        guard runPulseTimer == nil else { return }
        runPulse = 0
        runPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CACurrentMediaTime()
                self.runPulse = 0.5 + 0.5 * abs(sin(t * 4))
                self.needsDisplay = true
            }
        }
    }

    private func stopRunPulse() {
        runPulseTimer?.invalidate()
        runPulseTimer = nil
        runPulse = 0
    }
}
