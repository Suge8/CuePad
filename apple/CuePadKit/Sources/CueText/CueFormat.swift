import Foundation

public enum CueToken: Equatable, Sendable {
    case text(String)
    case image(String)
    case file(key: String, name: String)

    public var shownText: String {
        switch self {
        case .text(let text): text
        case .image: ""
        case .file(_, let name): name
        }
    }
}

public enum CueFormat {
    static let objectCharacter: UniChar = 0xFFFC

    static let scheme = "cuepad://file/"
    public static let referencePrefix = "](" + scheme
    static let imagePrefix = "![" + referencePrefix

    public static func imageMarkup(key: String) -> String { imagePrefix + key + ")" }

    public static func fileMarkup(key: String, name: String) -> String { "[" + fileName(name) + referencePrefix + key + ")" }

    public static func markup(key: String, name: String) -> String {
        AttachmentKey.isImage(key) ? imageMarkup(key: key) : fileMarkup(key: key, name: name)
    }

    public static func reference(key: String) -> String { scheme + key + ")" }

    public static func fileName(_ raw: String) -> String {
        let name = String(raw.map { $0 == "[" ? "(" : $0 == "]" ? ")" : $0.isNewline ? " " : $0 }).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "file" : name
    }

    public static func isRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

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

    /// 正文里有没有附件引用（图片或文件）。按字节找（memmem）：比 Foundation 的 `contains` 快约 20 倍，标准库的 `utf8.firstRange(of:)` 还要再慢 6 倍。
    public static func hasAttachments(_ stored: String) -> Bool {
        var stored = stored
        return stored.withUTF8 { contains($0, referencePrefixBytes) }
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBufferPointer { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
    }

    private static let threeNewlines = Array("\n\n\n".utf8)
    private static let referencePrefixBytes = Array(referencePrefix.utf8)

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

    private static func key(at text: Substring) -> (String, Substring.Index)? {
        guard let close = text.prefix(AttachmentKey.hashLength + 1 + AttachmentKey.formatLimit + 1).firstIndex(of: ")") else { return nil }
        let key = String(text[..<close])
        return AttachmentKey.isValid(key) ? (key, close) : nil
    }

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
