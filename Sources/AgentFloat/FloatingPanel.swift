import AppKit
import SwiftUI

/// 클릭·hover로 사용자가 작업 중인 앱의 포커스를 뺏으면 실패로 보는 창이다 (spec 2 실패 조건)
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        // nonactivatingPanel은 생성 뒤 styleMask를 바꿔서는 적용되지 않아 init에서 넘긴다
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // 데스크탑을 넘기는 중에도 따라 밀려가지 않고, 모든 데스크탑과 전체화면 앱 위의 같은 자리에 있어야 한다 (spec 4.8)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // SwiftUI 내용이 마우스 누름을 먼저 가져가 배경 끌기는 동작하지 않는다. 끌기는 WindowDragGesture 손잡이가 맡는다
        isMovableByWindowBackground = false
        // 이 앱은 거의 항상 비활성이라 NSPanel 기본값(true)이면 패널이 곧바로 사라진다
        hidesOnDeactivate = false
    }

    /// 답장 화면이 열린 동안만 켠다. 그 밖에 키 창이 되면 사용자가 타이핑하던 앱이 키 입력을 잃는다 (v1.2 설계 4.7 예외)
    var acceptsKeyInput = false

    override var canBecomeKey: Bool { acceptsKeyInput }
    override var canBecomeMain: Bool { false }
}

/// 패널이 키 창이 되지 않아 모든 클릭이 "비활성 창의 첫 클릭"으로 들어온다.
/// NSHostingView 기본값(false, 실행 중 값으로 확인)이면 그 클릭이 창 활성화용으로만 쓰이고 끌기·줄 클릭에 닿지 않을 수 있다
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
