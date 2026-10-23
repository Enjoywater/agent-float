/// 앱 아이콘을 어디에 둘지. 설정 메뉴는 메뉴바 아이콘과 Dock 아이콘의 우클릭 메뉴에 있어, 둘 다 숨기는 선택은 두지 않는다
public enum IconPresence: String, CaseIterable, Sendable {
    case menuBar, dock, both

    public var showsMenuBarIcon: Bool { self != .dock }
    public var showsDockIcon: Bool { self != .menuBar }

    /// 고른 적이 없으면 메뉴바만 — 늘 떠 있는 위젯이 Dock·⌘Tab 자리를 차지하지 않게 한다 (v1 설계 4.8)
    public static func resolve(saved: String?) -> IconPresence {
        saved.flatMap(IconPresence.init(rawValue:)) ?? .menuBar
    }
}
