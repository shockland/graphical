import AppKit
import GraphicalDomain

@MainActor
protocol OrgCanvasViewDelegate: AnyObject {
    func orgCanvasDidChangeSelection(_ canvas: OrgCanvasView)
    func orgCanvas(_ canvas: OrgCanvasView, didMoveNode id: String, to point: CGPoint, ended: Bool)
    func orgCanvasDidRequestAddNode(_ canvas: OrgCanvasView)
    func orgCanvas(_ canvas: OrgCanvasView, didCreateEdgeFrom: String, to: String, router: Bool)
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
        activeRunNodeId: String? = nil
    ) {
        self.org = org
        self.layout = layout
        self.selectedNodeId = selectedNodeId
        self.selectedEdgeId = selectedEdgeId
        self.activeRunNodeId = activeRunNodeId
        needsDisplay = true
        if selectedNodeId != nil || selectedEdgeId != nil {
            startSelectionPulse()
        }
        if activeRunNodeId != nil {
            startRunPulse()
        } else {
            stopRunPulse()
        }
    }

    func setTool(_ tool: OrgCanvasTool) {
        self.tool = tool
        connectFromId = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
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

        if let from = connectFromId, let pos = layout.nodes[from] {
            let start = nodeCenter(pos)
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
        Theme.border.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x: CGFloat = 0
        while x < bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
            x += step
        }
        var y: CGFloat = 0
        while y < bounds.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: bounds.width, y: y))
            y += step
        }
        path.stroke()
    }

    private func drawNode(_ node: OrgNode) {
        guard let pos = layout.nodes[node.id] else { return }
        let rect = nodeRect(pos)
        let isEntry = org.entry == node.id || (org.entry == nil && org.nodes.first?.id == node.id)
        let selected = selectedNodeId == node.id
        let isActiveRun = activeRunNodeId == node.id

        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        if isActiveRun {
            Theme.accentSoft.withAlphaComponent(0.45 + 0.35 * runPulse).setFill()
        } else {
            Theme.surface.setFill()
        }
        path.fill()

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

        if isActiveRun {
            let badge = "▶" as NSString
            badge.draw(
                in: NSRect(x: rect.maxX - 22, y: rect.minY + 34, width: 14, height: 14),
                withAttributes: [
                    .font: Theme.bodyFont(ofSize: 10, weight: .bold),
                    .foregroundColor: Theme.accent
                ]
            )
        }

        if isEntry {
            let bar = NSRect(x: rect.minX, y: rect.minY + 10, width: 4, height: rect.height - 20)
            let barPath = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
            Theme.accent.setFill()
            barPath.fill()
        }

        let role = node.role as NSString
        role.draw(
            in: NSRect(x: rect.minX + 14, y: rect.minY + 12, width: rect.width - 28, height: 18),
            withAttributes: [
                .font: Theme.bodyFont(ofSize: 13, weight: .semibold),
                .foregroundColor: Theme.text
            ]
        )

        let meta = "\(node.id) · \(node.runner)" as NSString
        meta.draw(
            in: NSRect(x: rect.minX + 14, y: rect.minY + 34, width: rect.width - 28, height: 16),
            withAttributes: [
                .font: Theme.bodyFont(ofSize: 11),
                .foregroundColor: Theme.muted
            ]
        )

        let chip = "\(node.model ?? "—")" as NSString
        let chipSize = chip.size(withAttributes: [.font: Theme.bodyFont(ofSize: 10, weight: .medium)])
        let chipRect = NSRect(
            x: rect.maxX - chipSize.width - 22,
            y: rect.minY + 12,
            width: chipSize.width + 10,
            height: 16
        )
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4)
        Theme.accentSoft.setFill()
        chipPath.fill()
        chip.draw(
            in: NSRect(x: chipRect.minX + 5, y: chipRect.minY + 1, width: chipSize.width, height: 14),
            withAttributes: [
                .font: Theme.bodyFont(ofSize: 10, weight: .medium),
                .foregroundColor: Theme.accent
            ]
        )
    }

    private func drawEdge(_ edge: OrgEdge) {
        guard let fromPos = layout.nodes[edge.from] else { return }
        let from = nodeCenter(fromPos)
        let selected = selectedEdgeId == edge.id

        let destinations: [CGPoint]
        switch edge.type {
        case .fixed:
            guard let toId = edge.to, let toPos = layout.nodes[toId] else { return }
            destinations = [nodeCenter(toPos)]
        case .router:
            destinations = edge.targets.compactMap { id in
                layout.nodes[id].map(nodeCenter)
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

    private func nodeRect(_ pos: NodePosition) -> CGRect {
        CGRect(x: pos.x, y: pos.y, width: Theme.nodeSize.width, height: Theme.nodeSize.height)
    }

    private func nodeCenter(_ pos: NodePosition) -> CGPoint {
        CGPoint(x: pos.x + Theme.nodeSize.width / 2, y: pos.y + Theme.nodeSize.height / 2)
    }

    private func viewToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    private func hitNode(at canvasPoint: CGPoint) -> String? {
        for node in org.nodes.reversed() {
            if let pos = layout.nodes[node.id], nodeRect(pos).contains(canvasPoint) {
                return node.id
            }
        }
        return nil
    }

    private func hitEdge(at canvasPoint: CGPoint) -> String? {
        for edge in org.edges {
            guard let fromPos = layout.nodes[edge.from] else { continue }
            let from = nodeCenter(fromPos)
            let tos: [CGPoint]
            switch edge.type {
            case .fixed:
                guard let toId = edge.to, let toPos = layout.nodes[toId] else { continue }
                tos = [nodeCenter(toPos)]
            case .router:
                tos = edge.targets.compactMap { layout.nodes[$0].map(nodeCenter) }
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
