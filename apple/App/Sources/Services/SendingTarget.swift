import CueStore

/// 发往同一处的话按它排队落库（`SendOrder`）、回复框按它先亮"发送中"（`Launching`）：会话按它自己（`ref`）认，同名的两个会话各排各的；没有 `ref` 的按名字。
struct SendingTarget: Hashable {
    private enum Place: Hashable {
        case cue
        case session(host: String, ref: String)
        case named(host: String, name: String)
    }

    private let place: Place
    static let cue = Self(place: .cue)

    init(host: String, target: SendTarget) {
        place = target.ref.map { .session(host: host, ref: $0) } ?? .named(host: host, name: target.name)
    }

    private init(place: Place) { self.place = place }
}
