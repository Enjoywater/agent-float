/// 답장 화면을 어디에 띄울지. 사용자가 메뉴에서 고른다 (v1.2 설계 4.5)
public enum ReplyPlacement: String, CaseIterable, Sendable {
    /// 패널 내용이 그 세션 하나로 바뀐다
    case panel
    /// 누른 대기 줄이 그 자리에서 길어진다
    case inline
    /// 패널 옆에 카드가 하나 더 뜬다
    case card

    /// 개발용 환경 변수가 저장한 선택보다 앞선다. 고른 적이 없으면 패널 전환 — 질문이 길어도 패널 크기가 거의 그대로다 [사용자]
    public static func resolve(override: String?, saved: String?) -> ReplyPlacement {
        override.flatMap(ReplyPlacement.init(rawValue:)) ?? saved.flatMap(ReplyPlacement.init(rawValue:)) ?? .panel
    }
}
