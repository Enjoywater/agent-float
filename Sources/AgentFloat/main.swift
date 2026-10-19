import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Info.plist의 LSUIElement와 같은 뜻이지만, Info.plist가 없는 `swift run` 실행에서도 Dock 아이콘이 생기지 않게 코드로도 지정한다
app.setActivationPolicy(.accessory)
app.run()
