import AppKit
import CoreGraphics
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first(where: { s in
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    return CGDisplayIsBuiltin(id) != 0
}) else { fatalError("Built-in display not found") }
let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "Agent Float 촬영 배경"
window.backgroundColor = CommandLine.arguments.contains("dark") ? NSColor(srgbRed: 0.086, green: 0.086, blue: 0.09, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
window.level = .normal
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
