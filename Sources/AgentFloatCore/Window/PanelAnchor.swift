import CoreGraphics

/// 접힌 알약 위치를 원점 대신 "붙어 있는 위쪽 모서리"로 기억한다.
/// 원점으로 저장하면 개수가 늘어 폭이 바뀌거나 펼친 프레임이 저장될 때 알약이 화면 가장자리에서 떨어져 보인다
public struct PanelAnchor: Equatable, Sendable {
    /// `trailing` 이면 알약의 오른쪽 위, 아니면 왼쪽 위 모서리
    public let corner: CGPoint
    public let trailing: Bool

    public init(corner: CGPoint, trailing: Bool) {
        self.corner = corner
        self.trailing = trailing
    }

    /// 어느 쪽에 붙일지는 `PanelGeometry.expandedFrame` 과 같은 규칙으로 정해야 펼칠 때 고정되는 모서리와 어긋나지 않는다
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
