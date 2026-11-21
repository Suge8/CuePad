import Foundation

public enum CueLineKind: Equatable, Sendable {
    case body
    case heading
    case list
    case fence
    case rule
    case code
}

public struct CueLineStyle: Equatable, Sendable {
    public var kind: CueLineKind
    public var markerLength: Int
    public var inlineCode: [NSRange]
    public var links: [CueLink]
    public var emphasis: [NSRange]

    public init(kind: CueLineKind, markerLength: Int, inlineCode: [NSRange], links: [CueLink] = [], emphasis: [NSRange] = []) {
        self.kind = kind
        self.markerLength = markerLength
        self.inlineCode = inlineCode
        self.links = links
        self.emphasis = emphasis
    }
}

public struct CueLink: Equatable, Sendable {
    public var label: NSRange
    public var syntax: [NSRange]
}

public struct CueDecorations: Sendable {
    public var fenceCount: Int { fences.count }
    private let fences: [Int]

    private static let fence = "```"

    public init(_ text: NSString) {
        fences = Self.fenceLocations(in: text)
    }

    public func style(ofLine line: String, at location: Int) -> CueLineStyle {
        if line.hasPrefix(Self.fence) {
            return CueLineStyle(kind: .fence, markerLength: line.utf16.count, inlineCode: [])
        }
        if fencesBefore(location) % 2 == 1 {
            return CueLineStyle(kind: .code, markerLength: 0, inlineCode: [])
        }
        if CueFormat.isRule(line) {
            return CueLineStyle(kind: .rule, markerLength: line.utf16.count, inlineCode: [])
        }
        let (kind, marker) = Self.classify(line)
        let code = Self.inlineCode(in: line)
        return CueLineStyle(kind: kind, markerLength: marker, inlineCode: code, links: Self.links(in: line, outside: code), emphasis: InlineMarkdown.emphasisMarkers(in: line))
    }

    private static func fenceLocations(in text: NSString) -> [Int] {
        var result: [Int] = []
        if text.hasPrefix(fence) { result.append(0) }
        var searchFrom = 0
        let needle = "\n" + fence
        while searchFrom < text.length {
            let found = text.range(of: needle, options: .literal, range: NSRange(location: searchFrom, length: text.length - searchFrom))
            guard found.location != NSNotFound else { break }
            result.append(found.location + 1)
            searchFrom = found.location + 1
        }
        return result
    }

    private func fencesBefore(_ location: Int) -> Int {
        var low = 0, high = fences.count
        while low < high {
            let mid = (low + high) / 2
            if fences[mid] < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func isBlankUnit(_ unit: Character) -> Bool { unit == " " || unit == "\t" }

    private static func classify(_ line: String) -> (CueLineKind, Int) {
        let chars = Array(line.prefix(32))
        var i = 0
        while i < chars.count, isBlankUnit(chars[i]) { i += 1 }
        let indent = i
        if indent == 0, i < chars.count, chars[i] == "#" {
            var hashes = 0
            while hashes < chars.count, chars[hashes] == "#" { hashes += 1 }
            if hashes <= 6, hashes < chars.count, isBlankUnit(chars[hashes]) {
                return (.heading, String(chars[...hashes]).utf16.count)
            }
        }
        if i < chars.count, chars[i] == ">" {
            var end = i + 1
            while end < chars.count, chars[end] == ">" || isBlankUnit(chars[end]) { end += 1 }
            return (.body, String(chars[..<end]).utf16.count)
        }
        var j = i
        if j < chars.count, chars[j] == "-" {
            j += 1
        } else {
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            guard j > i, j < chars.count, chars[j] == "." else { return (.body, 0) }
            j += 1
        }
        guard j < chars.count, isBlankUnit(chars[j]) else { return (.body, 0) }
        return (.list, String(chars[...j]).utf16.count)
    }

    private static func links(in line: String, outside code: [NSRange]) -> [CueLink] {
        guard line.contains("](") else { return [] }
        return line.matches(of: /\[([^\[\]\n]+)\]\(([^\s()]+)\)/).compactMap { match in
            let whole = NSRange(match.range, in: line)
            guard !code.contains(where: { NSIntersectionRange($0, whole).length > 0 }) else { return nil }
            let label = NSRange(match.output.1.startIndex..<match.output.1.endIndex, in: line)
            return CueLink(label: label, syntax: [
                NSRange(location: whole.location, length: 1),
                NSRange(location: NSMaxRange(label), length: NSMaxRange(whole) - NSMaxRange(label)),
            ])
        }
    }

    private static func inlineCode(in line: String) -> [NSRange] {
        let units = Array(line.utf16)
        let tick: UInt16 = 0x60
        var ranges: [NSRange] = []
        var i = 0
        while i < units.count {
            guard units[i] == tick else { i += 1; continue }
            var j = i + 1
            while j < units.count, units[j] != tick { j += 1 }
            guard j < units.count, j > i + 1 else { i = j; continue }
            ranges.append(NSRange(location: i, length: j + 1 - i))
            i = j + 1
        }
        return ranges
    }
}
