/// 分块编号样式。复制排版与分隔线标签共用。
public enum CueNumbering: String, Sendable, CaseIterable {
    case none, decimal, alpha, cjk

    /// 第 `index` 段（0 起）的编号文本；`none` 返回空串。
    public func label(forSegment index: Int) -> String {
        let ordinal = index + 1
        switch self {
        case .none: return ""
        case .decimal: return String(ordinal)
        case .alpha: return Self.alpha(ordinal)
        case .cjk: return Self.cjk(ordinal)
        }
    }

    private static func alpha(_ ordinal: Int) -> String {
        var value = ordinal
        var label = ""
        while value > 0 {
            value -= 1
            label = String(UnicodeScalar(UInt8(65 + value % 26))) + label
            value /= 26
        }
        return label
    }

    private static let cjkDigits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    private static func cjk(_ value: Int) -> String {
        if value > 99 { return String(value) }
        let tens = value / 10
        let ones = value % 10
        if tens == 0 { return cjkDigits[ones] }
        return (tens == 1 ? "" : cjkDigits[tens]) + "十" + cjkDigits[ones]
    }
}
