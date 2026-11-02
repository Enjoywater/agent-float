import AppKit
import CoreGraphics

final class SyntheticBackdrop: NSView {
    let mode: String
    init(frame: CGRect, mode: String) { self.mode = mode; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let dark = mode == "dark" || mode == "code"
        (dark ? NSColor(srgbRed: 0.086, green: 0.086, blue: 0.09, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)).setFill()
        bounds.fill()
        if mode == "vivid" || mode == "sonoma" {
            let colors: [NSColor] = mode == "vivid" ? [.systemPink, .systemBlue, .systemYellow] : [.systemIndigo, .systemPurple, .systemTeal]
            NSGradient(colors: colors)!.draw(in: bounds, angle: 35)
        }
        if mode == "doc" || mode == "code" {
            let lines = mode == "code" ? ["struct Example {", "    let retries = 3", "    func run() {", "        print(\"Sample output\")", "    }", "}"] : ["Project notes", "A fictional document for visual testing.", "Review the layout, spacing, and contrast.", "All content on this background is synthetic.", "No real sessions or documents are shown."]
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: dark ? NSColor.systemMint : NSColor.darkGray]
            for row in 0..<Int(bounds.height / 32) {
                lines[row % lines.count].draw(at: NSPoint(x: 35, y: CGFloat(row) * 32), withAttributes: attributes)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first(where: { screen in
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    return CGDisplayIsBuiltin(id) != 0
}) else { fatalError("Built-in display not found") }
let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "Agent Float Synthetic Backdrop"
window.contentView = SyntheticBackdrop(frame: CGRect(origin: .zero, size: screen.frame.size), mode: CommandLine.arguments.dropFirst().first ?? "light")
// Cover normal application windows so captures cannot include private content behind glass.
window.level = .floating
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
