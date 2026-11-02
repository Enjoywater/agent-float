import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Mirror LSUIElement in code so swift run without Info.plist also avoids a Dock icon.
app.setActivationPolicy(.accessory)
app.run()
