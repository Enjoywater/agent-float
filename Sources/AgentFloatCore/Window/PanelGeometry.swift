import CoreGraphics

/// Panel geometry uses AppKit coordinates: bottom-left origin, positive y upward.
/// Operate on rectangles without window objects so tests can simulate arbitrary display arrangements.
public enum PanelGeometry {
    public static let margin: CGFloat = 16

    /// When a saved position fits no screen, such as after disconnecting a monitor,
    /// restore to the main screen's upper-right to avoid clipped or invisible pills.
    public static func restoredOrigin(saved: CGPoint?, size: CGSize, visibleFrames: [CGRect]) -> CGPoint {
        if let saved {
            let rect = CGRect(origin: saved, size: size)
            if visibleFrames.contains(where: { $0.contains(rect) }) { return saved }
        }
        guard let first = visibleFrames.first else { return saved ?? .zero }
        return CGPoint(x: first.maxX - margin - size.width, y: first.maxY - margin - size.height)
    }

    /// Preserve the top and nearest side during expansion to keep the pill stationary.
    /// If anchoring would place content offscreen, visibility takes precedence.
    public static func expandedFrame(collapsed: CGRect, expandedSize: CGSize, visible: CGRect) -> CGRect {
        var origin = CGPoint(x: collapsed.minX, y: collapsed.maxY - expandedSize.height)
        if collapsed.midX > visible.midX {
            origin.x = collapsed.maxX - expandedSize.width
        }
        // Oversized panels cannot satisfy both edges; retain the summary at top and text start at left.
        origin.x = max(min(origin.x, visible.maxX - expandedSize.width), visible.minX)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - expandedSize.height)
        return CGRect(origin: origin, size: expandedSize)
    }

    /// Place side cards opposite the panel's anchored side, aligned to the selected row, then clamp onscreen (v1.2 design §4.5 B).
    public static func cardFrame(panel: CGRect, rowTop: CGFloat, size: CGSize, trailing: Bool, visible: CGRect, gap: CGFloat = 8) -> CGRect {
        let x = trailing ? panel.minX - gap - size.width : panel.maxX + gap
        var origin = CGPoint(x: x, y: rowTop - size.height)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        origin.x = max(min(origin.x, visible.maxX - size.width), visible.minX)
        return CGRect(origin: origin, size: size)
    }

    /// After dragging or display removal, clamp the pill onscreen with the smallest displacement.
    /// Returning to the default would discard the position the user just chose.
    public static func clamped(_ rect: CGRect, into visibleFrames: [CGRect]) -> CGRect {
        guard let target = closestFrame(to: rect, in: visibleFrames) else { return rect }
        var origin = rect.origin
        // Like expandedFrame, preserve top/left when content exceeds screen size.
        origin.x = max(min(origin.x, target.maxX - rect.width), target.minX)
        origin.y = min(max(origin.y, target.minY), target.maxY - rect.height)
        return CGRect(origin: origin, size: rect.size)
    }

    /// Choose the screen with greatest overlap, or the nearest when none overlap.
    private static func closestFrame(to rect: CGRect, in frames: [CGRect]) -> CGRect? {
        let overlaps = frames.map { ($0, overlapArea($0, rect)) }.filter { $0.1 > 0 }
        if let best = overlaps.max(by: { $0.1 < $1.1 }) { return best.0 }
        return frames.min { gap($0, rect) < gap($1, rect) }
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private static func gap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(0, lhs.minX - rhs.maxX, rhs.minX - lhs.maxX)
        let dy = max(0, lhs.minY - rhs.maxY, rhs.minY - lhs.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
