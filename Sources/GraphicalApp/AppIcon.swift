import AppKit

enum AppIcon {
    /// Dock / branding image bundled under `Resources/AppIcon.png`.
    static var image: NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
