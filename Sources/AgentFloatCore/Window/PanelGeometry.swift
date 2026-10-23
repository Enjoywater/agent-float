import CoreGraphics

/// AppKit 화면 좌표(왼쪽 아래 원점, y 위쪽)를 전제로 한 패널 위치 계산.
/// 창 객체 없이 사각형만 다뤄 테스트에서 화면 구성을 마음대로 만들 수 있게 한다.
public enum PanelGeometry {
    public static let margin: CGFloat = 16

    /// 모니터를 뗀 뒤처럼 저장 위치가 어느 화면에도 온전히 들어가지 않으면
    /// 알약이 반쯤 잘려 보이거나 아예 사라지므로 주 화면 오른쪽 위로 되돌린다.
    public static func restoredOrigin(saved: CGPoint?, size: CGSize, visibleFrames: [CGRect]) -> CGPoint {
        if let saved {
            let rect = CGRect(origin: saved, size: size)
            if visibleFrames.contains(where: { $0.contains(rect) }) { return saved }
        }
        guard let first = visibleFrames.first else { return saved ?? .zero }
        return CGPoint(x: first.maxX - margin - size.width, y: first.maxY - margin - size.height)
    }

    /// 펼칠 때 알약이 화면상 제자리에 남도록 위쪽 가장자리와, 화면 가장자리에 가까운 쪽의
    /// 옆 가장자리를 고정한다. 그래도 화면을 벗어나면 고정보다 보이는 쪽을 택한다.
    public static func expandedFrame(collapsed: CGRect, expandedSize: CGSize, visible: CGRect) -> CGRect {
        var origin = CGPoint(x: collapsed.minX, y: collapsed.maxY - expandedSize.height)
        if collapsed.midX > visible.midX {
            origin.x = collapsed.maxX - expandedSize.width
        }
        // 화면보다 큰 패널이면 두 조건을 동시에 못 지키므로, 요약 줄이 있는 위쪽과 글이 시작되는 왼쪽을 남긴다
        origin.x = max(min(origin.x, visible.maxX - expandedSize.width), visible.minX)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - expandedSize.height)
        return CGRect(origin: origin, size: expandedSize)
    }

    /// 옆 카드(v1.2 설계 4.5 B). 패널이 붙은 화면 가장자리의 반대쪽에 띄우고, 위쪽은 고른 줄에 맞춘 뒤 화면 안으로 밀어 넣는다
    public static func cardFrame(panel: CGRect, rowTop: CGFloat, size: CGSize, trailing: Bool, visible: CGRect, gap: CGFloat = 8) -> CGRect {
        let x = trailing ? panel.minX - gap - size.width : panel.maxX + gap
        var origin = CGPoint(x: x, y: rowTop - size.height)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        origin.x = max(min(origin.x, visible.maxX - size.width), visible.minX)
        return CGRect(origin: origin, size: size)
    }

    /// 끌어 놓은 자리나 빠진 모니터 때문에 알약이 화면 밖으로 나가면 가장 덜 움직이는 쪽으로 화면 안에 밀어 넣는다.
    /// 시작할 때처럼 기본 위치로 되돌리면, 사용자가 방금 고른 자리를 버리게 된다
    public static func clamped(_ rect: CGRect, into visibleFrames: [CGRect]) -> CGRect {
        guard let target = closestFrame(to: rect, in: visibleFrames) else { return rect }
        var origin = rect.origin
        // expandedFrame 과 같이 화면보다 크면 요약 줄이 있는 위쪽과 글이 시작되는 왼쪽을 남긴다
        origin.x = max(min(origin.x, target.maxX - rect.width), target.minX)
        origin.y = min(max(origin.y, target.minY), target.maxY - rect.height)
        return CGRect(origin: origin, size: rect.size)
    }

    /// 걸친 화면이 있으면 가장 많이 덮은 화면, 하나도 없으면 가장 가까운 화면
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
