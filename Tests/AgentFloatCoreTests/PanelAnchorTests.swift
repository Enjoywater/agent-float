import CoreGraphics
import Testing
import AgentFloatCore

@Suite struct PanelAnchorTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)

    @Test func rightHalfPillAnchorsTopRightCorner() {
        let pill = CGRect(x: 1348, y: 897, width: 148, height: 28)
        let anchor = PanelAnchor(pillFrame: pill, visible: screen)
        #expect(anchor == PanelAnchor(corner: CGPoint(x: 1496, y: 925), trailing: true))
        #expect(anchor.pillFrame(size: pill.size) == pill)
    }

    @Test func leftHalfPillAnchorsTopLeftCorner() {
        let pill = CGRect(x: 40, y: 600, width: 148, height: 28)
        let anchor = PanelAnchor(pillFrame: pill, visible: screen)
        #expect(anchor == PanelAnchor(corner: CGPoint(x: 40, y: 628), trailing: false))
        #expect(anchor.pillFrame(size: pill.size) == pill)

        let external = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let onExternalLeftHalf = CGRect(x: 1700, y: 300, width: 148, height: 28)
        #expect(PanelAnchor(pillFrame: onExternalLeftHalf, visible: external).trailing == false)
    }

    @Test func widthChangeKeepsAnchoredCorner() {
        let right = PanelAnchor(corner: CGPoint(x: 1496, y: 925), trailing: true)
        let wider = right.pillFrame(size: CGSize(width: 210, height: 28))
        #expect(wider.maxX == 1496)
        #expect(wider.maxY == 925)
        #expect(wider.width == 210)

        let left = PanelAnchor(corner: CGPoint(x: 40, y: 628), trailing: false)
        let narrower = left.pillFrame(size: CGSize(width: 60, height: 28))
        #expect(narrower.minX == 40)
        #expect(narrower.maxY == 628)
    }

    @Test func anchorAgreesWithExpandedFrameSide() {
        let size = CGSize(width: 280, height: 400)
        for pill in [CGRect(x: 1348, y: 897, width: 148, height: 28), CGRect(x: 40, y: 600, width: 148, height: 28)] {
            let anchor = PanelAnchor(pillFrame: pill, visible: screen)
            let expanded = PanelGeometry.expandedFrame(collapsed: pill, expandedSize: size, visible: screen)
            let expandedCorner = CGPoint(x: anchor.trailing ? expanded.maxX : expanded.minX, y: expanded.maxY)
            #expect(expandedCorner == anchor.corner)
        }
    }
}
