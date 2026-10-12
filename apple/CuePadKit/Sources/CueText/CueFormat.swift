import Foundation

/// 正文的结构化视图：卡片正文的存储格式与运行时 token 之间的桥。
public enum CueToken: Equatable, Sendable {
    case text(String)
    /// 内联图片，值为内容哈希（小写十六进制）。
    case image(String)
    /// 分割线（独占一行）。
    case split
}

/// 存储格式（纯字符串，唯一事实源）：
/// 分割线是独占一行的 `---split---`；
/// 图片是行内 `![](cuepad://img/<hash>)`。
public enum CueFormat {
    public static let splitMarker = "---split---"
    /// 运行时正文里分割线与图片各占的一个占位字符（NSTextAttachment 用的 U+FFFC）。
    public static let objectCharacter: UniChar = 0xFFFC

    /// 图片引用的开头；其后是内容哈希（小写十六进制）与 `)`。
    public static let imagePrefix = "![](cuepad://img/"

    /// 独占一行且 trim 后是分割标记时为分割线行。
    public static func isMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == splitMarker
    }

    public static func imageMarkup(id: String) -> String { imagePrefix + id + ")" }

    /// 发出去（发送、复制、分享）的正文：分割线只是一条线，写成 `---`；去掉首尾空白。
    public static func readable(_ stored: String) -> String {
        stored.components(separatedBy: "\n").map { isMarkerLine($0) ? "---" : $0 }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉图片后的文字（给输入框、分享、一行摘要）：分割线写成 `---`，图片留下的空行折叠，去掉首尾空白。
    public static func plainText(_ stored: String) -> String {
        parse(stored).map { token in
            switch token {
            case .text(let text): text
            case .split: "---"
            case .image: ""
            }
        }
        .joined()
        .replacing(/\n{3,}/, with: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 正文里引用的图片哈希，按出现顺序（可重复）。
    public static func imageHashes(in stored: String) -> [String] {
        guard stored.contains(imagePrefix) else { return [] }
        return parse(stored).compactMap { if case .image(let hash) = $0 { hash } else { nil } }
    }

    public static func parse(_ stored: String) -> [CueToken] {
        var tokens: [CueToken] = []
        for (index, line) in stored.components(separatedBy: "\n").enumerated() {
            if index > 0 { tokens.append(.text("\n")) }
            if isMarkerLine(line) {
                tokens.append(.split)
            } else {
                appendInline(line, to: &tokens)
            }
        }
        return tokens
    }

    public static func serialize(_ tokens: [CueToken]) -> String {
        tokens.map {
            switch $0 {
            case .text(let text): text
            case .image(let id): imageMarkup(id: id)
            case .split: splitMarker
            }
        }.joined()
    }

    private static func appendInline(_ line: String, to tokens: inout [CueToken]) {
        var rest = Substring(line)
        var pending = Substring()
        while let start = rest.range(of: imagePrefix) {
            let afterPrefix = rest[start.upperBound...]
            let hex = afterPrefix.prefix { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
            let close = afterPrefix[hex.endIndex...]
            guard !hex.isEmpty, close.first == ")" else {
                pending += rest[..<start.upperBound]
                rest = afterPrefix
                continue
            }
            pending += rest[..<start.lowerBound]
            if !pending.isEmpty { tokens.append(.text(String(pending))) }
            pending = Substring()
            tokens.append(.image(String(hex)))
            rest = close.dropFirst()
        }
        pending += rest
        if !pending.isEmpty { tokens.append(.text(String(pending))) }
    }
}
