/// User-selected reply placement (v1.2 design §4.5).
public enum ReplyPlacement: String, CaseIterable, Sendable {
    /// Replace the panel contents with one session's reply.
    case panel
    /// Expand the clicked waiting row in place.
    case inline
    /// Open an additional card beside the panel.
    case card

    /// Development overrides outrank saved preferences; default to panel replacement to keep long questions compact (user decision).
    public static func resolve(override: String?, saved: String?) -> ReplyPlacement {
        override.flatMap(ReplyPlacement.init(rawValue:)) ?? saved.flatMap(ReplyPlacement.init(rawValue:)) ?? .panel
    }
}
