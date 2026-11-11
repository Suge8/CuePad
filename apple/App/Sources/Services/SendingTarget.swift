import CueStore

struct SendingTarget: Hashable {
    private let value: String
    static let cue = Self(value: "cue")

    // 保留既有 host + 显示名的等价关系，包括分隔符；改用会话 ref 是另一次行为变更。
    init(host: String, target: SendTarget) { value = "\(host)\n\(target.name)" }
    private init(value: String) { self.value = value }
}
