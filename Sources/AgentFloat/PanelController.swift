import AgentFloatCore
import AppKit
import Observation
import SwiftUI

/// 펼침·접힘의 느낌을 정하는 값. 사용자가 나중에 손보기 쉽도록 한곳에 모은다 (spec 4.8 "자연스럽고 부드럽게")
enum Motion {
    static let expandDelay = scaled(0.15)
    static let collapseDelay = scaled(0.4)
    static let spring = Animation.spring(response: scaled(0.42), dampingFraction: 0.86)
    static let listFadeInDelay = scaled(0.08)
    static let listFadeIn = Animation.easeOut(duration: scaled(0.2))
    static let listFadeOut = Animation.easeIn(duration: scaled(0.12))
    /// 동작 줄이기에서 morph 대신 쓰는 전환
    static let crossfade = Animation.easeInOut(duration: scaled(0.15))
    static let sweepPeriod = scaled(2.6)
    /// 개수가 줄어 알약이 좁아질 때 창을 줄이기 전에 기다리는 시간. 내용의 spring 이 거의 멈춘 뒤에 줄여야 잘리지 않는다
    static let pillShrinkDelay = scaled(0.5)
    /// 경과 시간 표시가 분 단위라 이보다 자주 다시 그릴 필요가 없다
    static let labelTick: TimeInterval = 15

    static func isReduced(_ systemSetting: Bool) -> Bool {
        systemSetting || forceReduced
    }

    /// 시스템 설정을 바꾸지 않고 동작 줄이기 경로를 확인하려는 디버그 덮어쓰기
    private static let forceReduced = ProcessInfo.processInfo.environment["AGENT_FLOAT_REDUCE_MOTION"] == "1"
    /// 전환 중간 모습을 스크린샷으로 확인하려고 모든 시간을 늘린다 (예: 8이면 8배 느림)
    private static let slowFactor = Double(ProcessInfo.processInfo.environment["AGENT_FLOAT_SLOW_MOTION"] ?? "") ?? 1

    private static func scaled(_ seconds: Double) -> Double {
        seconds * slowFactor
    }
}

/// SwiftUI 쪽이 그리는 데 필요한 전환 단계. 단계를 넘기는 시점은 창 크기와 맞물려야 해서 `PanelController` 만 바꾼다
@MainActor @Observable
final class PanelPresentation {
    var isGlassExpanded = false
    var isListVisible = false
    var anchorsTrailing = true
    var pillWidth: CGFloat = Layout.pillHeight
    var panelHeight: CGFloat = Layout.panelChromeHeight
    var listHeight: CGFloat = 0
    /// 화면을 다시 그릴 일이 없는 값이라 관찰하지 않는다
    @ObservationIgnored var isDragging = false
}

/// 패널 프레임·hover·펼침 전환을 맡는다.
/// 창 크기는 애니메이션하지 않고 한 번에 바꾸며, 움직임은 SwiftUI 안에서만 일어난다 (spec 4.8)
@MainActor
final class PanelController: NSObject {
    private static let anchorKey = "panelAnchor"

    let panel: FloatingPanel
    let hostingView: PanelHostingView<FloatRootView>

    private let model: AppModel
    private let presentation: PanelPresentation
    private let hoverTracker = HoverTracker()
    private let pillMeasurer = NSHostingView(rootView: PillMeasure(summary: AppModel.emptySummary))
    private let listMeasurer = NSHostingView(rootView: ListMeasure(groups: [], unseen: []))

    private var anchor: PanelAnchor
    private var phase = Phase.collapsed
    /// 예약된 전환 단계가 그 사이 시작된 반대 방향 전환을 덮어쓰지 않도록 전환마다 올린다
    private var generation = 0
    /// 높이 전환이 겹치면 앞선 spring 의 완료가 뒤 전환 도중에 불려 창을 너무 일찍 줄인다(실측). 마지막 전환의 완료만 창을 맞춘다
    private var heightGeneration = 0
    private var isHovering = false
    private var isAdjustingFrame = false
    private var lastAppliedFrame = CGRect.zero
    private var hoverTask: Task<Void, Never>?
    private var listFadeTask: Task<Void, Never>?
    private var pillResizeTask: Task<Void, Never>?
    private var dragSettleTask: Task<Void, Never>?
    private var buttonWatchTask: Task<Void, Never>?
    private var mouseDownMonitor: Any?

    private enum Phase {
        case collapsed, expanded, collapsing
    }

    init(model: AppModel) {
        self.model = model
        let presentation = PanelPresentation()
        self.presentation = presentation

        let host = PanelHostingView(rootView: FloatRootView(model: model, presentation: presentation))
        // 창 크기는 이 컨트롤러가 정한다. 기본값이면 SwiftUI 내용 크기가 창 크기를 제약으로 묶어 펼침 전환과 충돌한다
        host.sizingOptions = []
        hostingView = host

        let size = Self.measurePill(pillMeasurer, summary: model.summary)
        anchor = Self.restoredAnchor(saved: Self.savedAnchor(), size: size)
        presentation.anchorsTrailing = anchor.trailing
        presentation.pillWidth = size.width

        let frame = anchor.pillFrame(size: size)
        panel = FloatingPanel(contentRect: frame)
        panel.contentView = host
        lastAppliedFrame = frame
        super.init()

        // 패널이 키 창이 되지 않아도 hover 를 받으려면 activeAlways 가 필요하다
        host.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverTracker,
            userInfo: nil
        ))
        hoverTracker.onChange = { [weak self] inside in self?.hoverChanged(inside) }
        model.onChange = { [weak self] in self?.modelDidChange() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelWillMove(_:)), name: NSWindow.willMoveNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove(_:)), name: NSWindow.didMoveNotification, object: panel
        )
        // 알약을 잡는 순간 펼침이 끼어들면 끌어야 할 알약이 패널로 바뀌어 버린다 (R35)
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.panel { self?.mouseWentDown() }
            }
            return event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func resetPosition() {
        let size = pillSize()
        anchor = Self.restoredAnchor(saved: nil, size: size)
        saveAnchor()
        // 펼쳐 있는 동안은 접힐 때 새 자리로 돌아간다
        guard phase == .collapsed else { return }
        presentation.anchorsTrailing = anchor.trailing
        presentation.pillWidth = size.width
        applyFrame(anchor.pillFrame(size: size))
    }

    /// 끈 직후 바로 종료하면 0.3초 뒤 저장이 실행되지 않아 위치를 잃으므로 종료 직전에 바로 저장한다 (R28)
    func flushPendingSave() {
        guard let task = dragSettleTask else { return }
        task.cancel()
        dragSettleTask = nil
        anchor = anchorFromWindow()
        saveAnchor()
    }

    func debugExpand() {
        hoverTask?.cancel()
        expand()
        _ = after(1) { controller in
            AppDelegate.logTrackingAreas(of: controller.hostingView)
            controller.logHitTests()
        }
    }

    /// 테두리 빛처럼 위에 얹힌 AppKit 뷰가 끌기·줄 클릭을 가로채는지는 실제 hitTest 결과로만 알 수 있다
    private func logHitTests() {
        let bounds = hostingView.bounds
        let probes = [
            ("summary", CGPoint(x: bounds.maxX - 30, y: Layout.pillHeight / 2)),
            ("row", CGPoint(x: bounds.midX, y: Layout.panelChromeHeight + 30)),
        ]
        for (name, point) in probes {
            guard let superview = hostingView.superview else { continue }
            let hit = superview.hitTest(hostingView.convert(point, to: superview))
            DebugLog.write("hitTest \(name)=\(hit.map { String(describing: type(of: $0)) } ?? "nil") attention=\(model.summary.attention)")
        }
    }

    func debugCollapse() {
        hoverTask?.cancel()
        collapse()
    }

    // MARK: hover

    private func hoverChanged(_ inside: Bool) {
        isHovering = inside
        DebugLog.write("hover inside=\(inside) phase=\(phase)")
        // 끄는 중에는 커서가 창과 함께 움직여 hover 가 의미 없고, 전환이 끼어들면 놓을 자리가 흔들린다 (spec 4.8)
        guard !presentation.isDragging else { return }
        scheduleHoverTransition()
    }

    private func scheduleHoverTransition() {
        hoverTask?.cancel()
        if isHovering {
            guard phase != .expanded, !Self.isPrimaryButtonDown else { return }
            hoverTask = after(Motion.expandDelay) { controller in
                // 대기하는 사이 버튼을 눌렀다면 끌려는 것이다
                guard !Self.isPrimaryButtonDown else { return }
                controller.expand()
            }
        } else {
            guard phase == .expanded else { return }
            hoverTask = after(Motion.collapseDelay) { $0.collapse() }
        }
    }

    private static var isPrimaryButtonDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
    }

    private func mouseWentDown() {
        hoverTask?.cancel()
        DebugLog.write("mouse down phase=\(phase)")
        // 끌기 고리(performDrag)가 손을 뗀 이벤트를 삼킬 수 있어 버튼 상태를 직접 지켜본다
        buttonWatchTask?.cancel()
        buttonWatchTask = Task { [weak self] in
            while Self.isPrimaryButtonDown {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.buttonWatchTask = nil
            DebugLog.write("mouse up phase=\(self.phase)")
            self.syncHover()
        }
    }

    /// 창 크기가 바뀌는 동안 진입·이탈 알림을 놓칠 수 있어 실제 커서 위치로 다시 맞춘다
    private func syncHover() {
        isHovering = panel.frame.contains(NSEvent.mouseLocation)
        guard !presentation.isDragging else { return }
        scheduleHoverTransition()
    }

    // MARK: 펼침·접힘

    private func expand() {
        // 세션이 없으면 펼쳐도 요약 줄 하나뿐이라 흐린 알약으로 둔다
        guard !presentation.isDragging, !model.sessions.isEmpty else { return }
        let pill = anchor.pillFrame(size: pillSize())
        let layout = expandedLayout(pill: pill)
        presentation.pillWidth = pill.width
        generation += 1
        let generation = generation
        pillResizeTask?.cancel()
        listFadeTask?.cancel()
        phase = .expanded
        model.isExpanded = true

        // 창을 먼저 목표 크기로 키운다. 내용이 고정 모서리에 붙어 있어 이 순간에도 알약은 제자리다
        presentation.anchorsTrailing = layout.trailing
        presentation.panelHeight = layout.panelHeight
        presentation.listHeight = layout.listHeight
        applyFrame(layout.windowFrame)
        // 커진 창에서 알약 자리를 먼저 확정해야 한다. 같은 갱신에 morph 를 시작하면 옛 창 기준 자리에서 미끄러져 들어온다(실측)
        hostingView.layoutSubtreeIfNeeded()
        DebugLog.write("expand frame=\(Self.describe(layout.windowFrame)) trailing=\(layout.trailing) list=\(layout.listHeight) reduced=\(isReduced)")

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.startExpandMotion(generation)
            }
        }
    }

    private func startExpandMotion(_ generation: Int) {
        if isReduced {
            withAnimation(Motion.crossfade) {
                presentation.isGlassExpanded = true
                presentation.isListVisible = true
            }
            return
        }
        withAnimation(Motion.spring) {
            presentation.isGlassExpanded = true
        }
        // 유리가 먼저 커지고 목록이 뒤따라야 "같은 유리가 늘어난다"로 읽힌다
        listFadeTask = after(Motion.listFadeInDelay) { controller in
            guard controller.generation == generation else { return }
            DebugLog.write("list fade-in")
            withAnimation(Motion.listFadeIn) {
                controller.presentation.isListVisible = true
            }
        }
    }

    private func collapse() {
        guard phase == .expanded else { return }
        // 펼친 동안 개수가 바뀌었으면 옛 폭의 알약으로 줄어들어 요약 줄이 잘린 뒤 튄다
        presentation.pillWidth = pillSize().width
        generation += 1
        let generation = generation
        listFadeTask?.cancel()
        phase = .collapsing
        model.isExpanded = false
        DebugLog.write("collapse begin reduced=\(isReduced)")

        if isReduced {
            withAnimation(Motion.crossfade) {
                presentation.isListVisible = false
                presentation.isGlassExpanded = false
            } completion: { [weak self] in
                self?.finishCollapse(generation)
            }
            return
        }
        // 목록이 먼저 사라진 뒤 유리가 줄어야 줄어드는 유리 밖으로 글자가 삐져나오지 않는다
        withAnimation(Motion.listFadeOut) {
            presentation.isListVisible = false
        } completion: { [weak self] in
            guard let self, self.generation == generation else { return }
            DebugLog.write("glass collapse")
            withAnimation(Motion.spring) {
                self.presentation.isGlassExpanded = false
            } completion: { [weak self] in
                self?.finishCollapse(generation)
            }
        }
    }

    /// 창은 morph 가 끝난 뒤에 줄인다. 먼저 줄이면 줄어드는 유리가 창 가장자리에서 잘린다
    private func finishCollapse(_ generation: Int) {
        guard self.generation == generation, phase == .collapsing else { return }
        // 접히는 도중에 끌기 시작했다면 저장된 자리가 아니라 지금 끌고 있는 자리에서 접혀야 한다
        if presentation.isDragging {
            anchor = anchorFromWindow()
        }
        phase = .collapsed
        let size = pillSize()
        // 펼친 채 화면 끝으로 끌었거나 그사이 모니터가 빠졌으면 접힌 알약이 화면 밖에 놓일 수 있다
        let onScreen = clampedAnchor(anchor, size: size)
        if onScreen != anchor {
            anchor = onScreen
            saveAnchor()
        }
        presentation.anchorsTrailing = anchor.trailing
        presentation.pillWidth = size.width
        let frame = anchor.pillFrame(size: size)
        applyFrame(frame)
        DebugLog.write("collapse end frame=\(Self.describe(frame))")
        syncHover()
    }

    private var isReduced: Bool {
        Motion.isReduced(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: 내용 변화

    private func modelDidChange() {
        switch phase {
        case .collapsed:
            resizePill()
        case .expanded:
            if model.sessions.isEmpty {
                collapse()
            } else {
                adjustExpandedHeight()
            }
        case .collapsing:
            // 접힘이 끝날 때 그 시점의 알약 크기로 창을 맞춘다
            break
        }
    }

    /// 넓어질 때는 창을 먼저 키우고, 좁아질 때는 내용 전환이 끝난 뒤 줄인다. 반대로 하면 바뀌는 동안 알약이 잘린다
    private func resizePill() {
        let size = pillSize()
        // 실행 직후의 빈 알약 폭으로는 화면 안이던 자리도 넓어진 알약은 넘칠 수 있어 다시 확인한다
        let onScreen = clampedAnchor(anchor, size: size)
        let relocated = onScreen != anchor
        anchor = onScreen
        if relocated { saveAnchor() }
        presentation.anchorsTrailing = anchor.trailing
        let target = anchor.pillFrame(size: size)
        pillResizeTask?.cancel()
        let resizeNow = relocated || target.width >= panel.frame.width
        if resizeNow {
            applyFrame(target)
            // 커진 창에서 알약 자리를 먼저 확정해야 폭 전환이 고정 모서리에서 시작한다
            hostingView.layoutSubtreeIfNeeded()
        }
        withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
            presentation.pillWidth = size.width
        }
        guard !resizeNow else { return }
        pillResizeTask = after(Motion.pillShrinkDelay) { controller in
            guard controller.phase == .collapsed else { return }
            controller.applyFrame(controller.anchor.pillFrame(size: controller.pillSize()))
        }
    }

    /// 펼친 동안 세션 수가 바뀌면 위쪽과 고정한 옆 가장자리는 그대로 두고 높이만 같은 spring 으로 맞춘다
    private func adjustExpandedHeight() {
        let layout = expandedLayout(pill: pillAtWindowCorner())
        guard layout.panelHeight != presentation.panelHeight else { return }
        let frame = expandedWindowFrame(height: layout.panelHeight)
        if frame.height > panel.frame.height { applyFrame(frame) }
        let generation = generation
        heightGeneration += 1
        let heightGeneration = heightGeneration
        DebugLog.write("adjust height panel=\(layout.panelHeight) list=\(layout.listHeight)")
        withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
            presentation.panelHeight = layout.panelHeight
            presentation.listHeight = layout.listHeight
        } completion: { [weak self] in
            guard let self, self.generation == generation, self.heightGeneration == heightGeneration, self.phase == .expanded else {
                DebugLog.write("height completion skipped (superseded)")
                return
            }
            // 줄어드는 도중에 다시 늘었을 수 있어, 잡아 둔 값이 아니라 지금 목표 높이로 창을 맞춘다
            let settled = self.expandedWindowFrame(height: self.presentation.panelHeight)
            self.applyFrame(settled)
            DebugLog.write("height settled window=\(settled.height) panel=\(self.presentation.panelHeight)")
        }
    }

    /// 위쪽과 고정한 옆 가장자리는 그대로 두고 높이만 바꾼 창 프레임
    private func expandedWindowFrame(height: CGFloat) -> CGRect {
        let current = panel.frame
        let visible = Self.visibleFrame(for: current)
        var frame = current
        frame.size.height = height
        frame.origin.y = max(current.maxY - height, visible.minY)
        return frame
    }

    private struct ExpandedLayout {
        let windowFrame: CGRect
        let trailing: Bool
        let panelHeight: CGFloat
        let listHeight: CGFloat
    }

    /// 목록 높이를 펼치기 전에 재야 창과 유리가 한 번에 목표 높이에 닿는다 (출렁임 없음, spec 4.8)
    private func expandedLayout(pill: CGRect) -> ExpandedLayout {
        let visible = Self.visibleFrame(for: pill)
        let contentHeight = Self.measureList(listMeasurer, groups: model.groups, unseen: model.unseen)
        // 세션이 많아도 화면 밖으로 넘치지 않게 하고 나머지는 스크롤로 본다 (Review Focus 2)
        let maxPanelHeight = floor(visible.height * Layout.maxHeightRatio)
        let panelHeight = min(Layout.panelChromeHeight + contentHeight, maxPanelHeight)
        let frame = PanelGeometry.expandedFrame(
            collapsed: pill,
            expandedSize: CGSize(width: Layout.panelWidth, height: panelHeight),
            visible: visible
        )
        return ExpandedLayout(
            windowFrame: frame,
            // PanelGeometry.expandedFrame 과 같은 규칙이어야 내용이 붙는 모서리와 창이 고정한 모서리가 같다
            trailing: pill.midX > visible.midX,
            panelHeight: panelHeight,
            listHeight: panelHeight - Layout.panelChromeHeight
        )
    }

    // MARK: 위치 (R27)

    /// 첫 이동 알림보다 먼저 와서, 끌기가 시작되는 순간 예약된 펼침을 막을 수 있다 (R35)
    @objc private func panelWillMove(_ notification: Notification) {
        guard !isAdjustingFrame else { return }
        beginDrag()
    }

    @objc private func panelDidMove(_ notification: Notification) {
        // 펼침·접힘으로 직접 바꾼 프레임은 사용자가 옮긴 것이 아니다
        guard !isAdjustingFrame, panel.frame.origin != lastAppliedFrame.origin else { return }
        beginDrag()
    }

    private func beginDrag() {
        if !presentation.isDragging {
            presentation.isDragging = true
            hoverTask?.cancel()
            DebugLog.write("drag began phase=\(phase)")
        }
        armDragSettle()
    }

    private func armDragSettle() {
        dragSettleTask?.cancel()
        dragSettleTask = after(.milliseconds(300)) { $0.dragSettled() }
    }

    /// 끄는 동안 이동 알림이 연달아 오므로 손을 뗀 뒤 한 번만 기록한다
    private func dragSettled() {
        // 누른 채 멈춰 있으면 아직 끄는 중이다
        if NSEvent.pressedMouseButtons & 1 != 0 {
            armDragSettle()
            return
        }
        dragSettleTask = nil
        presentation.isDragging = false
        lastAppliedFrame = panel.frame
        anchor = anchorFromWindow()
        saveAnchor()
        DebugLog.write("drag ended phase=\(phase) anchor=\(Self.describe(anchor))")
        // 접힌 알약을 화면 끝 너머로 놓았으면 저장한 자리(화면 안)로 바로 옮긴다. 펼친 채면 접힐 때 옮긴다
        if phase == .collapsed {
            presentation.anchorsTrailing = anchor.trailing
            applyFrame(anchor.pillFrame(size: pillSize()))
        }
        syncHover()
    }

    @objc private func screensDidChange(_ notification: Notification) {
        // 펼쳐 있는 동안은 접힐 때(finishCollapse) 같은 방식으로 화면 안에 넣는다
        guard phase == .collapsed else { return }
        let size = pillSize()
        let onScreen = clampedAnchor(anchor, size: size)
        guard onScreen != anchor else { return }
        anchor = onScreen
        saveAnchor()
        presentation.anchorsTrailing = anchor.trailing
        applyFrame(anchor.pillFrame(size: size))
    }

    /// 어느 단계든 알약은 창의 고정 모서리에 붙어 있으므로, 펼친 채 옮겼어도 그 모서리가 접힐 자리다
    private func anchorFromWindow() -> PanelAnchor {
        let pill = pillAtWindowCorner()
        let raw = PanelAnchor(pillFrame: pill, visible: Self.visibleFrame(for: pill))
        return clampedAnchor(raw, size: pill.size)
    }

    /// 화면 안이면 그대로 두어야 저장된 쪽(오른쪽·왼쪽)이 화면 가운데 근처에서 뒤집히지 않는다
    private func clampedAnchor(_ current: PanelAnchor, size: CGSize) -> PanelAnchor {
        let pill = current.pillFrame(size: size)
        let clamped = PanelGeometry.clamped(pill, into: NSScreen.screens.map(\.visibleFrame))
        guard clamped != pill else { return current }
        return PanelAnchor(pillFrame: clamped, visible: Self.visibleFrame(for: clamped))
    }

    private func pillAtWindowCorner() -> CGRect {
        let frame = panel.frame
        let trailing = presentation.anchorsTrailing
        let corner = CGPoint(x: trailing ? frame.maxX : frame.minX, y: frame.maxY)
        return PanelAnchor(corner: corner, trailing: trailing).pillFrame(size: pillSize())
    }

    private func applyFrame(_ frame: CGRect) {
        guard panel.frame != frame else { return }
        isAdjustingFrame = true
        defer { isAdjustingFrame = false }
        lastAppliedFrame = frame
        panel.setFrame(frame, display: true, animate: false)
    }

    private func saveAnchor() {
        let stored: [String: Any] = ["x": Double(anchor.corner.x), "y": Double(anchor.corner.y), "trailing": anchor.trailing]
        UserDefaults.standard.set(stored, forKey: Self.anchorKey)
        DebugLog.write("saved panelAnchor=\(Self.describe(anchor))")
    }

    private static func savedAnchor() -> PanelAnchor? {
        guard let stored = UserDefaults.standard.dictionary(forKey: anchorKey),
              let x = stored["x"] as? Double,
              let y = stored["y"] as? Double,
              let trailing = stored["trailing"] as? Bool
        else { return nil }
        return PanelAnchor(corner: CGPoint(x: x, y: y), trailing: trailing)
    }

    /// 저장한 모서리에 지금 폭의 알약을 붙여 보고, 어느 화면에도 온전히 들어가지 않으면 주 화면 오른쪽 위로 되돌린다
    private static func restoredAnchor(saved: PanelAnchor?, size: CGSize) -> PanelAnchor {
        let savedFrame = saved?.pillFrame(size: size)
        let origin = PanelGeometry.restoredOrigin(
            saved: savedFrame?.origin,
            size: size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        if let saved, origin == savedFrame?.origin { return saved }
        let frame = CGRect(origin: origin, size: size)
        return PanelAnchor(pillFrame: frame, visible: visibleFrame(for: frame))
    }

    private static func visibleFrame(for rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let best = screens.max { lhs, rhs in
            area(lhs.frame.intersection(rect)) < area(rhs.frame.intersection(rect))
        }
        guard let best, area(best.frame.intersection(rect)) > 0 else {
            return NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame ?? rect
        }
        return best.visibleFrame
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    // MARK: 크기 재기

    private func pillSize() -> CGSize {
        Self.measurePill(pillMeasurer, summary: model.summary)
    }

    private static func measurePill(_ measurer: NSHostingView<PillMeasure>, summary: PillSummary) -> CGSize {
        measurer.rootView = PillMeasure(summary: summary)
        return CGSize(width: ceil(measurer.fittingSize.width), height: Layout.pillHeight)
    }

    private static func measureList(_ measurer: NSHostingView<ListMeasure>, groups: [SessionGroup], unseen: Set<SessionKey>) -> CGFloat {
        measurer.rootView = ListMeasure(groups: groups, unseen: unseen)
        return ceil(measurer.fittingSize.height)
    }

    // MARK: 보조

    /// 대기 중 컨트롤러가 사라지면 예약도 의미가 없어 약하게 잡는다
    private func after(_ seconds: Double, _ action: @escaping @MainActor (PanelController) -> Void) -> Task<Void, Never> {
        after(.seconds(seconds), action)
    }

    private func after(_ delay: Duration, _ action: @escaping @MainActor (PanelController) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(rect.origin.x), \(rect.origin.y), \(rect.width), \(rect.height))"
    }

    private static func describe(_ anchor: PanelAnchor) -> String {
        "(\(anchor.corner.x), \(anchor.corner.y), \(anchor.trailing ? "trailing" : "leading"))"
    }
}

/// NSHostingView 가 스스로 쓰는 추적 영역의 알림과 섞이지 않도록 패널 진입·이탈만 따로 받는다
private final class HoverTracker: NSResponder {
    var onChange: (@MainActor (Bool) -> Void)?

    override func mouseEntered(with event: NSEvent) {
        onChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onChange?(false)
    }
}

/// 접힌 알약과 같은 모양을 화면 밖에서 재기 위한 뷰
struct PillMeasure: View {
    let summary: PillSummary

    var body: some View {
        SummaryRow(summary: summary).pillChrome()
    }
}

struct ListMeasure: View {
    let groups: [SessionGroup]
    let unseen: Set<SessionKey>

    var body: some View {
        SessionListContent(groups: groups, unseen: unseen, now: .now, canNavigate: { _ in false }, onActivate: { _ in })
            .frame(width: Layout.listWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}
