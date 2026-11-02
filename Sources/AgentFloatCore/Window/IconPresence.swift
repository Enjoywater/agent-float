/// Settings live in menu bar/Dock context menus; do not allow hiding both entry points.
public enum IconPresence: String, CaseIterable, Sendable {
    case menuBar, dock, both

    public var showsMenuBarIcon: Bool { self != .dock }
    public var showsDockIcon: Bool { self != .menuBar }

    /// Default to menu bar only so the persistent widget occupies neither Dock nor Command-Tab space (v1 design §4.8).
    public static func resolve(saved: String?) -> IconPresence {
        saved.flatMap(IconPresence.init(rawValue:)) ?? .menuBar
    }
}
