import Foundation

/// 正文按行的规则：哪些行有文字（卡片名字与摘要用），选中的文字怎么转成任务。
public enum CueLines {
    // 有文字的行只有一条规则，实现在私有的 `text(of:)`：不是分割线（`---`），且除图片引用
    // （存储格式的 `![](…)` 或运行时的 U+FFFC）外还有文字；文件链接算它的文件名。

    /// 这一行是不是卡片名字所在的那种行（有文字的行）。
    static func isTitleLine(_ line: String) -> Bool { !text(of: line).isEmpty }

    /// 正文里全部有文字的行（图片引用去掉、文件留文件名，空白折成单个空格），按出现顺序。
    static func contentLines(_ stored: String) -> [String] {
        stored.components(separatedBy: "\n").map(text(of:)).filter { !$0.isEmpty }
    }

    /// 转为任务：每个有文字的行一个任务，去掉开头的列表符号（`-` `*` `•`、`1.` `1)`）与复选框（`[ ]` `[x]`）。
    public static func taskLines(_ stored: String) -> [String] {
        contentLines(stored).map(stripListMarker).filter { !$0.isEmpty }
    }

    static func text(of line: String) -> String {
        guard !CueFormat.isRule(line) else { return "" }
        // 绝大多数行没有附件引用：不必拆成记号再拼回去
        var text = line
        if CueFormat.hasAttachments(line) { text = CueFormat.parse(line).map(\.shownText).joined() }
        let object = String(UnicodeScalar(CueFormat.objectCharacter)!)
        return text.replacingOccurrences(of: object, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 任务的正文拆成标题与下面的话：第一个有文字的行是标题，其余（文字与图片，原样）是要交代给 Agent 的话；只有那一行时为 nil。
    public static func split(_ stored: String) -> (title: String, rest: String?) {
        var lines = stored.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: isTitleLine) else { return (stored, nil) }
        let heading = lines.remove(at: index)
        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !contentLines(rest).isEmpty || !CueFormat.attachmentKeys(in: rest).isEmpty
        return (heading, hasContent ? rest : nil)
    }

    /// `split` 反过来：标题一行，下面接着要交代的话；话是空白时只有标题。
    public static func joined(title: String, rest: String?) -> String {
        guard let rest, !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        return title + "\n" + rest
    }

    private static func stripListMarker(_ line: String) -> String {
        line.replacing(/^(?:[-*•]|\d+[.)])\s+/, with: "", maxReplacements: 1)
            .replacing(/^\[[ xX]?\]\s*/, with: "", maxReplacements: 1)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 名字（任务、子任务、会话名）多长：按显示宽度，汉字、假名、谚文、全角符号与表情算 2，其余算 1，不超过 `limit`（约 12 个汉字）。
/// Cue 写的名字超了退回给它重写（不截断：截出来的半句话等于假装写成了）；机器生成的（会话名生成的任务名、按任务名起的会话名）用 `clipped`；
/// 你手打的不限。
public enum CueName {
    public static let limit = 24

    public static func width(_ text: String) -> Int {
        text.reduce(0) { sum, character in sum + (character.unicodeScalars.contains(where: isWide) ? 2 : 1) }
    }

    /// 超过 `limit` 时截到放得下末尾的"…"为止。
    public static func clipped(_ text: String) -> String {
        guard width(text) > limit else { return text }
        var kept = "", used = 1
        for character in text {
            used += width(String(character))
            guard used <= limit else { break }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic || scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303F, 0x3040...0x33FF, 0xAC00...0xD7A3, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6: return true
        default: return false
        }
    }
}

/// 卡片的标题与摘要（唯一规则，App、小组件、命令行共用）。卡片没有标题字段：
/// 标题 = 首个有文字的行（见 `CueLines.isTitleLine`）去掉开头的 `#`（Markdown 标题前缀）；
/// 摘要 = 标题之后的第一段（跳过开头的空行，到下一个空行、分割线或只有图片的行为止），各行以空格连接，最多 `previewLimit` 字——
/// 一张卡只露出开头那一段，卡与卡之间才看得出差别。
public struct CueSummary: Equatable, Sendable {
    static let previewLimit = 240
    /// 搜索摘要里命中处之前留的字数。
    public static let snippetLead = 12

    public var title: String
    public var preview: String
    /// 正文里第一个 http(s) 链接的域名（去掉 www.），卡片上当小标；没有链接为 nil。
    public var linkHost: String?

    public init(_ stored: String) {
        // 只读到标题之后第一段的末尾为止：长正文的后半段不用解析
        var lines = Lines(rest: Substring(stored))
        title = Self.title(from: &lines)
        var paragraph: [String] = []
        while let line = lines.next() {
            if !line.isEmpty {
                paragraph.append(line)
            } else if !paragraph.isEmpty {
                break
            }
        }
        preview = String(paragraph.joined(separator: " ").prefix(Self.previewLimit))
        linkHost = stored.range(of: "http").flatMap { stored[$0.lowerBound...].firstMatch(of: /https?:\/\/[^\s\/?#)\]]+/) }
            .flatMap { URL(string: String($0.output))?.host() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    /// 只要标题时用它（`Card.heading`、各处的卡片名字）：读到第一个有文字的行就停，不解析摘要与链接。
    public static func title(of stored: String) -> String {
        var lines = Lines(rest: Substring(stored))
        return title(from: &lines)
    }

    private static func title(from lines: inout Lines) -> String {
        while let line = lines.next() {
            if !line.isEmpty { return stripHeading(line) }
        }
        return ""
    }

    /// 正文按 `\n` 逐行取有文字的部分（`CueLines.text(of:)`），用到哪行切到哪行：不先把整篇切成数组。
    private struct Lines: IteratorProtocol {
        var rest: Substring?

        mutating func next() -> String? {
            guard let current = rest else { return nil }
            let end = current.firstIndex(of: "\n")
            rest = end.map { current[current.index(after: $0)...] }
            return CueLines.text(of: String(current[..<(end ?? current.endIndex)]))
        }
    }

    /// 搜索结果里的摘要：标题之后的全部文字里第一处命中（不分大小写）离开头较远时，从命中处往前留 `snippetLead` 字截起、前面加"…"，
    /// 让人看到为什么搜到它；没命中、命中在开头附近或只在标题里时就是普通摘要（`whole` 时是标题之后的全文）。
    /// iOS 的搜索结果与 Mac ⌘K 的预览同用这一个；`whole` 给预览面板：不截到 `previewLimit`，保留换行。
    public static func snippet(_ stored: String, matching terms: [String], whole: Bool = false) -> String {
        let body = rest(stored, separator: whole ? "\n" : " ")
        let hit = terms.filter { !$0.isEmpty }.compactMap { body.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        guard let hit, body.distance(from: body.startIndex, to: hit) > snippetLead else { return whole ? body : CueSummary(stored).preview }
        let tail = body[body.index(hit, offsetBy: -snippetLead)...]
        return "…" + (whole ? tail : tail.prefix(previewLimit))
    }

    private static func rest(_ stored: String, separator: String = "\n") -> String {
        CueLines.contentLines(stored).dropFirst().joined(separator: separator)
    }

    private static func stripHeading(_ line: String) -> String {
        let rest = line.drop { $0 == "#" }
        return rest.count < line.count ? rest.trimmingCharacters(in: .whitespaces) : line
    }
}

extension String {
    /// 至多 `limit` 个字符，超出的以省略号结尾（省略号算在内）。
    public func clipped(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(limit - 1)) + "…"
    }

    /// 第一个非空行，去掉首尾空格；没有为 nil。
    public var firstLine: String? {
        split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
