#!/usr/bin/env swift
/// Repro: long unwrapped NSTextField labels + 0.58 split → window growth.
/// Documents that NSWindow contentMaxSize does NOT stop Auto Layout growth
/// (maxSize only applies during user resize).
///
/// Exit 0 = unwrapped case grows AND wrap mitigations keep fitting near initial width.
/// Exit 1 = unexpected (bug pattern missing or fix ineffective).
import AppKit

let long = String(repeating: "ABCDEFGHIJ", count: 80) // 800 chars, no spaces
let initialWidth: CGFloat = 900
let screenCap: CGFloat = 1400

func makeLabel(_ s: String) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.translatesAutoresizingMaskIntoConstraints = false
    f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    return f
}

func buildConsole(wrapLabels: Bool) -> (NSWindow, NSView) {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: 600))
    view.translatesAutoresizingMaskIntoConstraints = false

    let left = NSView()
    left.translatesAutoresizingMaskIntoConstraints = false
    let right = NSView()
    right.translatesAutoresizingMaskIntoConstraints = false

    let log = NSTextField(labelWithString: "[agent stdout] \(long)")
    log.translatesAutoresizingMaskIntoConstraints = false
    log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    if wrapLabels {
        log.maximumNumberOfLines = 0
        log.lineBreakMode = .byWordWrapping
        log.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        log.preferredMaxLayoutWidth = 400
    }
    left.addSubview(log)

    let handoffStack = NSStackView()
    handoffStack.orientation = .vertical
    handoffStack.alignment = .leading
    handoffStack.translatesAutoresizingMaskIntoConstraints = false
    let summary = makeLabel(long)
    let path = makeLabel("/Users/chris/Projects/Graphical/.graphical/artifacts/" + long)
    if wrapLabels {
        for label in [summary, path] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
    }
    handoffStack.addArrangedSubview(summary)
    handoffStack.addArrangedSubview(path)

    let rightStack = NSStackView(views: [handoffStack])
    rightStack.orientation = .vertical
    rightStack.alignment = .leading
    rightStack.translatesAutoresizingMaskIntoConstraints = false
    rightStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

    let handoffScroll = NSScrollView()
    handoffScroll.translatesAutoresizingMaskIntoConstraints = false
    handoffScroll.hasVerticalScroller = true
    handoffScroll.hasHorizontalScroller = false
    handoffScroll.documentView = rightStack
    right.addSubview(handoffScroll)

    view.addSubview(left)
    view.addSubview(right)

    let leftWidth = left.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.58)
    leftWidth.priority = .defaultHigh

    NSLayoutConstraint.activate([
        left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        left.topAnchor.constraint(equalTo: view.topAnchor),
        left.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        leftWidth,

        right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
        right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        right.topAnchor.constraint(equalTo: view.topAnchor),
        right.bottomAnchor.constraint(equalTo: view.bottomAnchor),

        log.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16),
        log.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
        log.topAnchor.constraint(equalTo: left.topAnchor, constant: 16),

        handoffScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
        handoffScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
        handoffScroll.topAnchor.constraint(equalTo: right.topAnchor),
        handoffScroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),

        rightStack.widthAnchor.constraint(equalTo: handoffScroll.widthAnchor),
        handoffStack.widthAnchor.constraint(equalTo: rightStack.widthAnchor, constant: -32)
    ])

    if wrapLabels {
        summary.widthAnchor.constraint(equalTo: handoffStack.widthAnchor).isActive = true
        path.widthAnchor.constraint(equalTo: handoffStack.widthAnchor).isActive = true
        summary.preferredMaxLayoutWidth = 300
        path.preferredMaxLayoutWidth = 300
    }

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 600),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    // Deliberately set — reproves these do not stop Auto Layout growth.
    window.contentMaxSize = NSSize(width: screenCap, height: 900)
    window.maxSize = NSSize(width: screenCap, height: 900)
    window.contentView = view

    return (window, view)
}

func measure(wrapLabels: Bool) -> CGFloat {
    let (window, view) = buildConsole(wrapLabels: wrapLabels)
    window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    window.layoutIfNeeded()
    let fitting = view.fittingSize.width
    print("wrap=\(wrapLabels) fitting=\(Int(fitting)) window=\(Int(window.frame.width))")
    return fitting
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("--- long text without wrap (expects huge fitting width) ---")
let broken = measure(wrapLabels: false)
print("--- with wrap mitigations (expects ~initial width) ---")
let fixed = measure(wrapLabels: true)

let grew = broken > initialWidth * 1.5
let contained = fixed <= initialWidth * 1.15
print("grew=\(grew) contained=\(contained)")
exit(grew && contained ? 0 : 1)
