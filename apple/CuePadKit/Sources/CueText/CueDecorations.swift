import Foundation

public enum CueLineKind: Equatable, Sendable {
    case body
    /// `## 标题`
    case heading
    /// `- ` 或 `1. ` 列表项
    case list
    /// ``` 围栏行本身
    case fence
    /// 围栏之内的行
    case code
}

/// 一行的轻装饰描述。标记字符保留可见，宿主只降低它们的存在感，不做所见即所得。
public struct CueLineStyle: Equatable, Sendable {
    public var kind: CueLineKind
    /// 是否是卡片标题。
    public var isTitle: Bool
    /// 行首标记（缩进 + `##␣`、`-␣`、`1.␣`，或整条围栏行）的 UTF-16 长度；无标记为 0。
    public var markerLength: Int
    /// 行内 code（含两侧反引号）的范围，相对行首。
    public var inlineCode: [NSRange]

    public init(kind: CueLineKind, isTitle: Bool, markerLength: Int, inlineCode: [NSRange]) {
        self.kind = kind
        self.isTitle = isTitle
        self.markerLength = markerLength
        self.inlineCode = inlineCode
    }
}

/// 一份运行时正文的装饰上下文：标题位置与围栏位置是全文性质，逐行样式据此判定。
/// 范围对齐 Electron 版：`^#{1,6}\s`、`^\s*-\s`、顶格 ``` 围栏，另加有序列表、行内 code 与标题行。
public struct CueDecorations: Sendable {
    /// 标题行（`CueSegments.isTitleLine`）的行首偏移；没有则为 nil。
    public let titleLocation: Int?
    /// 顶格 ``` 围栏行的数量。奇数说明有围栏未闭合，其后的行都是代码。
    public var fenceCount: Int { fences.count }
    private let fences: [Int]

    private static let fence = "```"

    public init(_ buffer: CueBuffer) {
        titleLocation = Self.titleLocation(in: buffer)
        fences = Self.fenceLocations(in: buffer.text)
    }

    /// `line` 是不含换行的行内容，`location` 是它的行首偏移。
    public func style(ofLine line: String, at location: Int) -> CueLineStyle {
        let isTitle = location == titleLocation
        if line.hasPrefix(Self.fence) {
            return CueLineStyle(kind: .fence, isTitle: isTitle, markerLength: line.utf16.count, inlineCode: [])
        }
        if fencesBefore(location) % 2 == 1 {
            return CueLineStyle(kind: .code, isTitle: isTitle, markerLength: 0, inlineCode: [])
        }
        let (kind, marker) = Self.classify(line)
        return CueLineStyle(kind: kind, isTitle: isTitle, markerLength: marker, inlineCode: Self.inlineCode(in: line))
    }

    // MARK: 全文性质

    /// 标题行的判定只有一处：`CueSegments.isTitleLine`。
    private static func titleLocation(in buffer: CueBuffer) -> Int? {
        var location = 0
        while location <= buffer.length {
            let line = buffer.line(at: location)
            let text = buffer.text.substring(with: NSRange(location: line.start, length: line.end - line.start))
            if CueSegments.isTitleLine(text) { return line.start }
            location = line.end + 1
        }
        return nil
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

    // MARK: 行内

    private static func isBlankUnit(_ unit: Character) -> Bool { unit == " " || unit == "\t" }

    private static func classify(_ line: String) -> (CueLineKind, Int) {
        let chars = Array(line.prefix(32))  // 标记只出现在行首，长行不必整行展开
        var i = 0
        while i < chars.count, isBlankUnit(chars[i]) { i += 1 }
        let indent = i
        // 标题只允许顶格
        if indent == 0, i < chars.count, chars[i] == "#" {
            var hashes = 0
            while hashes < chars.count, chars[hashes] == "#" { hashes += 1 }
            if hashes <= 6, hashes < chars.count, isBlankUnit(chars[hashes]) {
                return (.heading, String(chars[...hashes]).utf16.count)
            }
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
