public enum CueBlockActionKind: Sendable {
    case copy, send
}

/// 用户在某个块上触发的动作：分隔线上的按钮或 Cmd+Shift+C。
public struct CueBlockAction: Equatable, Sendable {
    public var kind: CueBlockActionKind
    /// 块在 `CueSegments.parse` 结果里的下标。分隔线按钮作用于其后一块。
    public var blockIndex: Int
    /// 块正文（存储格式，未 trim，图片仍是 `![](cuepad://img/…)`）。
    public var text: String

    public init(kind: CueBlockActionKind, blockIndex: Int, text: String) {
        self.kind = kind
        self.blockIndex = blockIndex
        self.text = text
    }
}
