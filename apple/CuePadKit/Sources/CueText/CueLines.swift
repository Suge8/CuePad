import Foundation

/// 正文按行的规则：哪些行有文字（卡片标题与摘要、编辑器标题行装饰用），选中的文字怎么转成任务。
public enum CueLines {
    // 有文字的行只有一条规则，实现在私有的 `text(of:)`：不是分割线，且除图片引用
    // （存储格式的 `![](…)` 或运行时的 U+FFFC）外还有文字。

    /// 这一行是不是标题行（有文字的行）。
    public static func isTitleLine(_ line: String) -> Bool { !text(of: line).isEmpty }

    /// 正文里全部有文字的行（去掉图片引用，空白折成单个空格），按出现顺序。
    static func contentLines(_ stored: String) -> [String] {
        stored.components(separatedBy: "\n").map(text(of:)).filter { !$0.isEmpty }
    }

    /// 转为任务：每个有文字的行一个任务，去掉开头的列表符号（`-` `*` `•`、`1.` `1)`）与复选框（`[ ]` `[x]`）。
    public static func taskLines(_ stored: String) -> [String] {
        contentLines(stored).map(stripListMarker).filter { !$0.isEmpty }
    }

    static func text(of line: String) -> String {
        guard !CueFormat.isMarkerLine(line) else { return "" }
        // 绝大多数行没有图片引用：不必拆成记号再拼回去
        var text = line
        if line.contains(CueFormat.imagePrefix) {
            text = CueFormat.parse(line).compactMap { token -> String? in
                if case .text(let text) = token { text } else { nil }
            }.joined()
        }
        let object = String(UnicodeScalar(CueFormat.objectCharacter)!)
        return text.replacingOccurrences(of: object, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func stripListMarker(_ line: String) -> String {
        line.replacing(/^(?:[-*•]|\d+[.)])\s+/, with: "", maxReplacements: 1)
            .replacing(/^\[[ xX]?\]\s*/, with: "", maxReplacements: 1)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 任务的正文：标题与可选的一句说明（任务是一件要做成的事；要交给 Agent 的话是挂在它下面的提示词）。
/// 存成两行：第一行标题，第二行说明。
public struct CueTask: Equatable, Sendable {
    public var title: String
    public var note: String

    public init(title: String, note: String = "") {
        self.title = title
        self.note = note
    }

    public init(_ stored: String) {
        title = CueSummary(stored).title
        note = CueLines.contentLines(stored).dropFirst().joined(separator: " ")
    }

    public var stored: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? title : "\(title)\n\(note)"
    }

    /// 一段多行的话变成任务时拆开：第一个有文字的行留给任务，其余（文字与图片，原样）成为它的一条提示词；只有那一行时提示词为 nil。
    public static func split(_ stored: String) -> (task: String, prompt: String?) {
        var lines = stored.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: CueLines.isTitleLine) else { return (stored, nil) }
        let heading = lines.remove(at: index)
        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !CueLines.contentLines(rest).isEmpty || !CueFormat.imageHashes(in: rest).isEmpty
        return (heading, hasContent ? rest : nil)
    }
}

/// 卡片的标题与摘要（唯一规则，App、小组件、命令行共用）。卡片没有标题字段：
/// 标题 = 首个有文字的行（见 `CueLines.isTitleLine`）去掉开头的 `#`（Markdown 标题前缀）；
/// 摘要 = 标题之后的第一段（跳过开头的空行，到下一个空行、分割线或只有图片的行为止），各行以空格连接，最多 `previewLimit` 字——
/// 一张卡只露出开头那一段，卡与卡之间才看得出差别。
public struct CueSummary: Equatable, Sendable {
    public static let previewLimit = 240
    /// 搜索摘要里命中处之前留的字数。
    public static let snippetLead = 12

    public var title: String
    public var preview: String
    /// 正文里第一个 http(s) 链接的域名（去掉 www.），卡片上当小标；没有链接为 nil。
    public var linkHost: String?

    public init(_ stored: String) {
        // 只读到标题之后第一段的末尾为止：长正文的后半段不用解析
        var heading: String?
        var paragraph: [String] = []
        for raw in stored.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = CueLines.text(of: String(raw))
            if heading == nil {
                if !line.isEmpty { heading = Self.stripHeading(line) }
            } else if !line.isEmpty {
                paragraph.append(line)
            } else if !paragraph.isEmpty {
                break
            }
        }
        title = heading ?? ""
        preview = String(paragraph.joined(separator: " ").prefix(Self.previewLimit))
        linkHost = stored.range(of: "http").flatMap { stored[$0.lowerBound...].firstMatch(of: /https?:\/\/[^\s\/?#)\]]+/) }
            .flatMap { URL(string: String($0.output))?.host() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
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

    /// 标题之后的全部文字，各行以 `separator` 连接。
    private static func rest(_ stored: String, separator: String = "\n") -> String {
        CueLines.contentLines(stored).dropFirst().joined(separator: separator)
    }

    private static func stripHeading(_ line: String) -> String {
        let rest = line.drop { $0 == "#" }
        return rest.count < line.count ? rest.trimmingCharacters(in: .whitespaces) : line
    }
}
