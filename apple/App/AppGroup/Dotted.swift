import SwiftUI

/// "·"只用在同一件事并列的短信息之间：计数、版本、状态词、名字与属性（"10 推进中 · 1 等你"、"已接入 · Pi 0.9"）。
/// 两段读起来像一句话的（出了什么事接说了什么、原因接下一步、动作接说明），写成一个字符串用中文标点，不进这里：
/// "没装上：脚本退出了"、"正式版在用，先用 X 指定目录"，不是"没装上 · 脚本退出了"。
/// 后半段自己带逗号的用"："（"没有在同步：开发用的隔离库，不连 iCloud"）。
///
/// 一行里用"·"隔开几段的字（"25 条灵感 · 3 项任务"）：屏幕上写"·"，读屏读逗号停顿。全 App 拼这种分段只经这里——
/// 别处直接写 " · " 的字面量会被 lint.sh 拦下；显示用 `Text(dotted)`（自带读屏文字），要字符串时取 `visible` / `spoken`。
nonisolated struct Dotted: Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    /// 分段处的写法（唯一一处字面量）；`PiProgress.action` 解析的同步数据另用 `PiSessionState.detailSeparator`。
    static let separator = " · "

    /// 各段；空段与 nil 不留。
    let parts: [String]

    init(_ parts: [String?]) { self.parts = parts.compactMap { $0 }.filter { !$0.isEmpty } }
    init(_ parts: String?...) { self.init(parts) }
    init(stringLiteral value: String) { self.init([value]) }
    init(stringInterpolation: DefaultStringInterpolation) { self.init([String(stringInterpolation: stringInterpolation)]) }

    var isEmpty: Bool { parts.isEmpty }
    var visible: String { parts.joined(separator: Self.separator) }
    var spoken: String { parts.joined(separator: String(localized: "，", comment: "读屏在分段处停顿的标点")) }

    var nonEmpty: Dotted? { isEmpty ? nil : self }

    static func + (lhs: Dotted, rhs: Dotted) -> Dotted { Dotted(lhs.parts + rhs.parts) }
}

extension Text {
    /// 屏幕上是"a · b"，读屏读"a，b"。Dotted 能由字面量构成：不退让的话 `Text("…")` 会选中这里、原样显示不走本地化。
    @_disfavoredOverload
    init(_ dotted: Dotted) { self = Text(verbatim: dotted.visible).accessibilityLabel(dotted.spoken) }
}

extension Dotted {
    /// 带样式的拼接（`Text("\\(a)\\(Text(sep))\\(b)")`）里的分隔：只给显示，整句的读屏文字由调用处自己给。
    static var inline: Text { Text(separator) }
}
