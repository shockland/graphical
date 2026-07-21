import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Theme is a light palette; keep native controls (popups, fields) on aqua
        // so dark-mode system text doesn't disappear on white surfaces.
        NSApp.appearance = NSAppearance(named: .aqua)
        if let icon = AppIcon.image {
            NSApp.applicationIconImage = icon
        }
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
