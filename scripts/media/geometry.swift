import AppKit
import CoreGraphics
import Foundation

// A locked display cannot prove that the synthetic backdrop covers the captured pixels.
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
if session?["CGSSessionScreenIsLocked"] as? Bool == true {
    FileHandle.standardError.write(Data("Screen is locked; media capture is paused.\n".utf8))
    exit(2)
}

if CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let selected = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    print(String(data: try JSONSerialization.data(withJSONObject: selected), encoding: .utf8)!)
} else {
    let screen = NSScreen.screens.first { screen in
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        return CGDisplayIsBuiltin(id) != 0
    }!
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    let bounds = CGDisplayBounds(id)
    // Configure only the isolated media bundle, never the installed app's preferences.
    let defaults = UserDefaults(suiteName: "dev.enjoywater.agent-float.media")!
    defaults.set(["x": screen.frame.maxX - 200, "y": screen.visibleFrame.maxY - 100, "trailing": true], forKey: "panelAnchor")
    defaults.synchronize()
    print(String(data: try JSONSerialization.data(withJSONObject: ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]), encoding: .utf8)!)
}
