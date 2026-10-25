import Foundation

/// 正文里的文字与图片（发送、预览时按原顺序切开用）。
public enum CueToken: Equatable, Sendable {
    case text(String)
    /// 内联图片，值为内容哈希（小写十六进制）。
    case image(String)
}

/// 存储格式：正文就是一段标准 Markdown（唯一事实源）。图片是行内 `![](cuepad://img/<hash>)`，分割线就是 `---`。
/// 编辑器里图片显示成附件（U+FFFC），其余照原文编辑。
public enum CueFormat {
    /// 编辑器运行时正文里图片占的一个占位字符（NSTextAttachment 用的 U+FFFC）。
    static let objectCharacter: UniChar = 0xFFFC

    /// 图片引用的开头；其后是内容哈希（小写十六进制）与 `)`。
    public static let imagePrefix = "![](cuepad://img/"

    public static func imageMarkup(id: String) -> String { imagePrefix + id + ")" }

    /// Markdown 的分割线（thematic break）：一行里只有三个以上同一种 `-` `*` `_`，中间可夹空白，行首缩进不超过三格。
    public static func isRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// 去掉图片、只留文字（输入框、分享、一行摘要，收不了图片的会话 `AgentCapabilities.images`）：图片留下的空行折叠，去掉首尾空白。
    public static func plainText(_ stored: String) -> String {
        let text = hasImages(stored) ? parse(stored).map { if case .text(let text) = $0 { text } else { "" } }.joined() : stored
        return collapsingBlankLines(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 连着三个以上的换行折成两个（空行最多留一行）。按字节做：Swift 的正则在这条每条消息都过一次的路径上慢一个数量级。
    static func collapsingBlankLines(_ text: String) -> String {
        var text = text
        let collapsed: String? = text.withUTF8 { bytes in
            guard contains(bytes, threeNewlines) else { return nil }
            let newline = UInt8(ascii: "\n")
            var kept: [UInt8] = [], run = 0
            kept.reserveCapacity(bytes.count)
            for byte in bytes {
                run = byte == newline ? run + 1 : 0
                if run <= 2 { kept.append(byte) }
            }
            return String(decoding: kept, as: UTF8.self)
        }
        return collapsed ?? text
    }

    /// 正文里有没有图片引用。按字节找（memmem）：比 Foundation 的 `contains` 快约 20 倍，标准库的 `utf8.firstRange(of:)` 还要再慢 6 倍。
    public static func hasImages(_ stored: String) -> Bool {
        var stored = stored
        return stored.withUTF8 { contains($0, imagePrefixBytes) }
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBufferPointer { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
    }

    private static let threeNewlines = Array("\n\n\n".utf8)
    private static let imagePrefixBytes = Array(imagePrefix.utf8)

    /// 正文里引用的图片哈希，按出现顺序（可重复）。
    public static func imageHashes(in stored: String) -> [String] {
        guard hasImages(stored) else { return [] }
        return parse(stored).compactMap { if case .image(let hash) = $0 { hash } else { nil } }
    }

    public static func parse(_ stored: String) -> [CueToken] {
        var tokens: [CueToken] = []
        var rest = Substring(stored)
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
        return tokens
    }

    public static func serialize(_ tokens: [CueToken]) -> String {
        tokens.map {
            switch $0 {
            case .text(let text): text
            case .image(let id): imageMarkup(id: id)
            }
        }.joined()
    }
}
