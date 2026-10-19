import CoreGraphics
import Testing
import AgentFloatCore

@Suite struct PanelGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let pill = CGSize(width: 148, height: 32)
    let expanded = CGSize(width: 280, height: 400)

    @Test func savedOriginInsideScreenIsKept() {
        let saved = CGPoint(x: 200, y: 300)
        #expect(PanelGeometry.restoredOrigin(saved: saved, size: pill, visibleFrames: [screen]) == saved)

        let external = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let onExternal = CGPoint(x: 2000, y: 100)
        #expect(PanelGeometry.restoredOrigin(saved: onExternal, size: pill, visibleFrames: [screen, external]) == onExternal)

        let flushTopRight = CGPoint(x: 1512 - 148, y: 945 - 32)
        #expect(PanelGeometry.restoredOrigin(saved: flushTopRight, size: pill, visibleFrames: [screen]) == flushTopRight)
    }

    @Test func offscreenOriginFallsBackToTopRight() {
        let fallback = CGPoint(x: 1512 - 16 - 148, y: 945 - 16 - 32)
        #expect(PanelGeometry.restoredOrigin(saved: CGPoint(x: 5000, y: 5000), size: pill, visibleFrames: [screen]) == fallback)
        #expect(PanelGeometry.restoredOrigin(saved: nil, size: pill, visibleFrames: [screen]) == fallback)

        let halfOffRightEdge = CGPoint(x: 1450, y: 300)
        #expect(PanelGeometry.restoredOrigin(saved: halfOffRightEdge, size: pill, visibleFrames: [screen]) == fallback)

        let detachedMonitorSpot = CGPoint(x: 2000, y: 100)
        #expect(PanelGeometry.restoredOrigin(saved: detachedMonitorSpot, size: pill, visibleFrames: [screen]) == fallback)

        #expect(PanelGeometry.restoredOrigin(saved: nil, size: pill, visibleFrames: []) == .zero)
    }

    @Test func expandAnchorsRightEdgeOnRightHalf() {
        let collapsed = CGRect(x: 1348, y: 897, width: 148, height: 32)
        let frame = PanelGeometry.expandedFrame(collapsed: collapsed, expandedSize: expanded, visible: screen)
        #expect(frame == CGRect(x: 1496 - 280, y: 929 - 400, width: 280, height: 400))
        #expect(frame.maxX == collapsed.maxX)
        #expect(frame.maxY == collapsed.maxY)
    }

    @Test func expandAnchorsLeftEdgeOnLeftHalf() {
        let collapsed = CGRect(x: 16, y: 897, width: 148, height: 32)
        let frame = PanelGeometry.expandedFrame(collapsed: collapsed, expandedSize: expanded, visible: screen)
        #expect(frame == CGRect(x: 16, y: 929 - 400, width: 280, height: 400))

        let secondScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let leftHalfOfSecond = CGRect(x: 1600, y: 1000, width: 148, height: 32)
        let onSecond = PanelGeometry.expandedFrame(collapsed: leftHalfOfSecond, expandedSize: expanded, visible: secondScreen)
        #expect(onSecond.minX == leftHalfOfSecond.minX)
        #expect(onSecond.maxY == leftHalfOfSecond.maxY)
    }

    @Test func expandedFrameIsPushedInsideScreen() {
        let nearBottom = CGRect(x: 100, y: 40, width: 148, height: 32)
        let pushedUp = PanelGeometry.expandedFrame(collapsed: nearBottom, expandedSize: expanded, visible: screen)
        #expect(pushedUp == CGRect(x: 100, y: 0, width: 280, height: 400))

        let dockInset = CGRect(x: 0, y: 70, width: 1512, height: 845)
        let aboveDock = PanelGeometry.expandedFrame(collapsed: nearBottom.offsetBy(dx: 0, dy: 40), expandedSize: expanded, visible: dockInset)
        #expect(aboveDock.minY == dockInset.minY)
        #expect(dockInset.contains(aboveDock))

        let narrow = CGRect(x: 0, y: 0, width: 300, height: 945)
        let leftAnchoredOverflowingRight = CGRect(x: 60, y: 500, width: 148, height: 32)
        let pushedLeft = PanelGeometry.expandedFrame(collapsed: leftAnchoredOverflowingRight, expandedSize: expanded, visible: narrow)
        #expect(pushedLeft.maxX == narrow.maxX)
        #expect(narrow.contains(pushedLeft))

        let oversized = PanelGeometry.expandedFrame(
            collapsed: CGRect(x: 1348, y: 897, width: 148, height: 32),
            expandedSize: CGSize(width: 2000, height: 1200),
            visible: screen
        )
        #expect(oversized.maxY == screen.maxY)
        #expect(oversized.minX == screen.minX)
    }
}

@Suite struct PanelGeometryClampTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let external = CGRect(x: 1512, y: -200, width: 1920, height: 1080)

    @Test func pillInsideScreenIsUnchanged() {
        let pill = CGRect(x: 200, y: 300, width: 148, height: 28)
        #expect(PanelGeometry.clamped(pill, into: [screen]) == pill)
    }

    @Test func pillPartlyOffRightEdgeIsPushedInsideNotReset() {
        let pill = CGRect(x: 1450, y: 300, width: 148, height: 28)
        #expect(PanelGeometry.clamped(pill, into: [screen]) == CGRect(x: 1512 - 148, y: 300, width: 148, height: 28))

        let aboveTop = CGRect(x: 600, y: 930, width: 148, height: 28)
        #expect(PanelGeometry.clamped(aboveTop, into: [screen]) == CGRect(x: 600, y: 945 - 28, width: 148, height: 28))
    }

    @Test func pillOnRemovedDisplayGoesToNearestScreen() {
        let onDetachedExternal = CGRect(x: 2000, y: 100, width: 148, height: 28)
        #expect(PanelGeometry.clamped(onDetachedExternal, into: [screen]) == CGRect(x: 1512 - 148, y: 100, width: 148, height: 28))

        let farLeft = CGRect(x: -900, y: 2000, width: 148, height: 28)
        let left = CGRect(x: -1800, y: 0, width: 1800, height: 1131)
        #expect(PanelGeometry.clamped(farLeft, into: [screen, left]) == CGRect(x: -900, y: 1131 - 28, width: 148, height: 28))
    }

    @Test func pillStraddlingTwoScreensStaysOnTheOneItMostlyCovers() {
        let mostlyOnExternal = CGRect(x: 1500, y: 300, width: 148, height: 28)
        #expect(PanelGeometry.clamped(mostlyOnExternal, into: [screen, external]) == CGRect(x: 1512, y: 300, width: 148, height: 28))
    }

    @Test func noScreensLeavesPillAlone() {
        let pill = CGRect(x: 5000, y: 5000, width: 148, height: 28)
        #expect(PanelGeometry.clamped(pill, into: []) == pill)
    }
}
