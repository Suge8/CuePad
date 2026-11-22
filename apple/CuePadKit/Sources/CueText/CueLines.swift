import Foundation

public enum CueLines {
    static func isTitleLine(_ line: String) -> Bool { !text(of: line).isEmpty }

    static func contentLines(_ stored: String) -> [String] {
        stored.components(separatedBy: "\n").map(text(of:)).filter { !$0.isEmpty }
    }

    public static func taskLines(_ stored: String) -> [String] {
        contentLines(stored).map(stripListMarker).filter { !$0.isEmpty }
    }

    static func text(of line: String) -> String {
        guard !CueFormat.isRule(line) else { return "" }
        var text = line
        if CueFormat.hasAttachments(line) { text = CueFormat.parse(line).map(\.shownText).joined() }
        let object = String(UnicodeScalar(CueFormat.objectCharacter)!)
        return text.replacingOccurrences(of: object, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func split(_ stored: String) -> (title: String, rest: String?) {
        var lines = stored.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: isTitleLine) else { return (stored, nil) }
        let heading = lines.remove(at: index)
        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !contentLines(rest).isEmpty || !CueFormat.attachmentKeys(in: rest).isEmpty
        return (heading, hasContent ? rest : nil)
    }

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

public enum CueName {
    public static let limit = 24

    public static func width(_ text: String) -> Int {
        text.reduce(0) { sum, character in sum + (character.unicodeScalars.contains(where: isWide) ? 2 : 1) }
    }

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

public struct CueSummary: Equatable, Sendable {
    static let previewLimit = 240
    public static let snippetLead = 12

    public var title: String
    public var preview: String
    public var linkHost: String?

    public init(_ stored: String, inline: (String) -> String = { $0 }) {
        var lines = Lines(rest: Substring(stored))
        title = inline(Self.title(from: &lines))
        var paragraph: [String] = []
        while let line = lines.next() {
            if !line.isEmpty {
                paragraph.append(line)
            } else if !paragraph.isEmpty {
                break
            }
        }
        preview = String(inline(paragraph.joined(separator: "\n")).replacingOccurrences(of: "\n", with: " ").prefix(Self.previewLimit))
        linkHost = stored.range(of: "http").flatMap { stored[$0.lowerBound...].firstMatch(of: /https?:\/\/[^\s\/?#)\]]+/) }
            .flatMap { URL(string: String($0.output))?.host() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

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

    private struct Lines: IteratorProtocol {
        var rest: Substring?

        mutating func next() -> String? {
            guard let current = rest else { return nil }
            let end = current.firstIndex(of: "\n")
            rest = end.map { current[current.index(after: $0)...] }
            return CueLines.text(of: String(current[..<(end ?? current.endIndex)]))
        }
    }

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
    public func clipped(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(limit - 1)) + "…"
    }

    public var firstLine: String? {
        split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
