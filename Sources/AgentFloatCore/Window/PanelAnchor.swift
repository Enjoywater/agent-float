import CoreGraphics

/// Persist the collapsed pill's anchored upper corner rather than its origin.
/// Saving origins lets width changes or expanded frames detach the pill from the display edge.
public struct PanelAnchor: Equatable, Sendable {
    /// Trailing identifies the upper-right corner; otherwise use upper-left.
    public let corner: CGPoint
    public let trailing: Bool

    public init(corner: CGPoint, trailing: Bool) {
        self.corner = corner
        self.trailing = trailing
    }

    /// Choose the side using the same rule as expandedFrame to preserve the anchored corner on expansion.
    public init(pillFrame: CGRect, visible: CGRect) {
        let trailing = pillFrame.midX > visible.midX
        self.init(
            corner: CGPoint(x: trailing ? pillFrame.maxX : pillFrame.minX, y: pillFrame.maxY),
            trailing: trailing
        )
    }

    public func pillFrame(size: CGSize) -> CGRect {
        let minX = trailing ? corner.x - size.width : corner.x
        return CGRect(x: minX, y: corner.y - size.height, width: size.width, height: size.height)
    }
}
