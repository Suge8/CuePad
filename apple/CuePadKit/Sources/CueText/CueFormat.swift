import Foundation

/// 正文里的文字与附件（发送、预览时按原顺序切开用）。附件的值是键（`AttachmentKey`）。
public enum CueToken: Equatable, Sendable {
    case text(String)
    /// 内联图片
    case image(String)
    /// 别的文件：键与显示的文件名（`CueFormat.fileName` 洗过）
    case file(key: String, name: String)

    /// 只看文字时它是什么：图片没有字，文件是它的文件名。
    public var shownText: String {
        switch self {
        case .text(let text): text
        case .image: ""
        case .file(_, let name): name
        }
    }
}

/// 存储格式：正文就是一段标准 Markdown（唯一事实源）。附件的地址只有一种 `cuepad://file/<键>`：
/// 图片嵌入写 `![](cuepad://file/<键>)`，别的文件是链接 `[文件名](cuepad://file/<键>)`；分割线就是 `---`。
/// 编辑器里附件显示成 U+FFFC，其余照原文编辑。
public enum CueFormat {
    /// 编辑器运行时正文里附件占的一个占位字符（NSTextAttachment 用的 U+FFFC）。
    static let objectCharacter: UniChar = 0xFFFC

    static let scheme = "cuepad://file/"
    /// 每个附件引用都含的一截（链接文字之后、键之前）：判断有没有附件、在库里按 SQL 找带附件的行都按它。
    public static let referencePrefix = "](" + scheme
    /// 图片引用的开头（其后是键与 `)`）。
    public static let imagePrefix = "![" + referencePrefix

    public static func imageMarkup(key: String) -> String { imagePrefix + key + ")" }

    public static func fileMarkup(key: String, name: String) -> String { "[" + fileName(name) + referencePrefix + key + ")" }

    /// 一个附件写进正文的样子：能内联显示的图片（`AttachmentKey.isImage`）嵌入，其余写成文件链接。
    public static func markup(key: String, name: String) -> String {
        AttachmentKey.isImage(key) ? imageMarkup(key: key) : fileMarkup(key: key, name: name)
    }

    /// 某个键的引用都含的那一截（不论图片还是文件、文件名是什么）：判断引用、回收时按它找。
    public static func reference(key: String) -> String { scheme + key + ")" }

    /// 存进正文的文件名：链接文字里不能有 `[` `]` 与换行（会切坏引用），换成圆括号与空格；空的叫 file。
    public static func fileName(_ raw: String) -> String {
        let name = String(raw.map { $0 == "[" ? "(" : $0 == "]" ? ")" : $0.isNewline ? " " : $0 }).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "file" : name
    }

    /// Markdown 的分割线（thematic break）：一行里只有三个以上同一种 `-` `*` `_`，中间可夹空白，行首缩进不超过三格。
    public static func isRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// 只留文字（输入框、分享、一行摘要）：图片去掉、文件留文件名，空行折叠，去掉首尾空白。
    public static func plainText(_ stored: String) -> String {
        let text = hasAttachments(stored) ? parse(stored).map(\.shownText).joined() : stored
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

    /// 正文里有没有附件引用（图片或文件）。
    public static func hasAttachments(_ stored: String) -> Bool {
        var stored = stored
        return stored.withUTF8 { contains($0, referencePrefixBytes) }
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBufferPointer { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
    }

    private static let threeNewlines = Array("\n\n\n".utf8)
    private static let imagePrefixBytes = Array(imagePrefix.utf8)
    private static let referencePrefixBytes = Array(referencePrefix.utf8)

    /// 正文里引用的图片的键，按出现顺序（可重复）。
    public static func imageKeys(in stored: String) -> [String] {
        guard hasImages(stored) else { return [] }
        return parse(stored).compactMap { if case .image(let key) = $0 { key } else { nil } }
    }

    /// 正文里引用的全部附件的键，按出现顺序（可重复）：登记附件记录、回收、等文件到本机都按它。
    public static func attachmentKeys(in stored: String) -> [String] {
        guard hasAttachments(stored) else { return [] }
        return parse(stored).compactMap {
            switch $0 {
            case .image(let key), .file(let key, _): key
            case .text: nil
            }
        }
    }

    public static func parse(_ stored: String) -> [CueToken] {
        var tokens: [CueToken] = []
        var rest = Substring(stored)
        var pending = Substring()
        while let found = rest.range(of: referencePrefix) {
            let afterPrefix = rest[found.upperBound...]
            guard let (key, close) = key(at: afterPrefix), let (open, token) = linkText(before: found.lowerBound, in: rest, key: key) else {
                pending += rest[..<found.upperBound]
                rest = afterPrefix
                continue
            }
            pending += rest[..<open]
            if !pending.isEmpty { tokens.append(.text(String(pending))) }
            pending = Substring()
            tokens.append(token)
            rest = afterPrefix[close...].dropFirst()
        }
        pending += rest
        if !pending.isEmpty { tokens.append(.text(String(pending))) }
        return tokens
    }

    /// 地址里的键与其后 `)` 的位置；不是合法的键接 `)` 为 nil。
    private static func key(at text: Substring) -> (String, Substring.Index)? {
        guard let close = text.prefix(AttachmentKey.hashLength + 1 + AttachmentKey.formatLimit + 1).firstIndex(of: ")") else { return nil }
        let key = String(text[..<close])
        return AttachmentKey.isValid(key) ? (key, close) : nil
    }

    /// 链接文字：从 `](` 往前到这一行里最近的 `[`，中间不能有方括号。空的且前面是 `!` 是图片（从 `!` 起），有字的是文件。
    private static func linkText(before end: Substring.Index, in text: Substring, key: String) -> (Substring.Index, CueToken)? {
        let head = text[..<end]
        guard let open = head.lastIndex(where: { $0 == "[" || $0 == "]" || $0.isNewline }), head[open] == "[" else { return nil }
        let name = head[head.index(after: open)...]
        if !name.isEmpty { return (open, .file(key: key, name: String(name))) }
        guard open > head.startIndex, head[head.index(before: open)] == "!" else { return nil }
        return (head.index(before: open), .image(key))
    }

    public static func serialize(_ tokens: [CueToken]) -> String {
        tokens.map {
            switch $0 {
            case .text(let text): text
            case .image(let key): imageMarkup(key: key)
            case .file(let key, let name): fileMarkup(key: key, name: name)
            }
        }.joined()
    }
}
