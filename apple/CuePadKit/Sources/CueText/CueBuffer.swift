import Foundation

/// 编辑器运行时正文的只读视图：UTF-16 文本里分隔线和图片各占一个 U+FFFC，
/// 由宿主回答哪个位置是分隔线。所有分块编辑都是对它的纯函数，坐标为 UTF-16 偏移。
public struct CueBuffer {
    public let text: NSString
    public let isSplit: (Int) -> Bool

    public init(text: NSString, isSplit: @escaping (Int) -> Bool) {
        self.text = text
        self.isSplit = isSplit
    }

    public var length: Int { text.length }

    /// 一行的正文范围 `[start, end)`，不含行尾换行。只认 `\n`，与存储格式一致。
    struct Line {
        var start: Int
        var end: Int
    }

    private static let newline: UInt16 = 0x0A

    func line(at location: Int) -> Line {
        let loc = min(max(location, 0), length)
        var start = loc
        while start > 0, text.character(at: start - 1) != Self.newline { start -= 1 }
        var end = loc
        while end < length, text.character(at: end) != Self.newline { end += 1 }
        return Line(start: start, end: end)
    }

    func isSplitLine(_ line: Line) -> Bool { line.end - line.start == 1 && isSplit(line.start) }

    private func isBlank(_ line: Line) -> Bool {
        (line.start..<line.end).allSatisfy {
            Unicode.Scalar(text.character(at: $0)).map(\.properties.isWhitespace) ?? false
        }
    }

    private func allLines() -> [Line] {
        var lines: [Line] = []
        var start = 0
        for i in 0..<length where text.character(at: i) == Self.newline {
            lines.append(Line(start: start, end: i))
            start = i + 1
        }
        lines.append(Line(start: start, end: length))
        return lines
    }
}

/// 一次文本替换加变更后的光标位置。`insert` 里的 U+FFFC 表示一个分隔线控件。
public struct CueEdit: Equatable, Sendable {
    public var range: NSRange
    public var insert: String
    public var caret: Int
}

/// 分隔线在文档里的位置与编号信息。
public struct CueDivider: Equatable, Sendable {
    /// 分隔线占位字符的偏移。
    public var location: Int
    /// 其后一块在 `CueSegments.parse` 结果里的下标。
    public var blockIndex: Int
    /// 其后一块的编号序号（0 起，只数非空块，与 `CueSegments.format` 一致）。
    public var sequence: Int
}

extension CueBuffer {
    private static let object = String(UnicodeScalar(CueFormat.objectCharacter)!)

    // MARK: 编辑

    /// Shift+Enter 切块：光标前内容留在当前块，光标后内容成为新块开头；选区被分隔线替换；
    /// 光标在空行上时整行变分隔线，不残留多余空行。
    public func splitEdit(selection: NSRange) -> CueEdit {
        let line = line(at: selection.location)
        if selection.length == 0, isBlank(line) {
            let atEnd = line.end == length
            return CueEdit(
                range: NSRange(location: line.start, length: line.end - line.start),
                insert: atEnd ? Self.object + "\n" : Self.object,
                caret: line.start + 2)
        }
        let insert = selection.location == line.start ? Self.object + "\n" : "\n" + Self.object + "\n"
        return CueEdit(range: selection, insert: insert, caret: selection.location + insert.utf16.count)
    }

    /// 块首 Backspace 合并块：前一行是分隔线时整条删除（保留一个换行）；否则 nil，回落默认行为。
    public func mergeBackward(selection: NSRange) -> CueEdit? {
        guard selection.length == 0 else { return nil }
        let line = line(at: selection.location)
        guard selection.location == line.start, line.start > 0 else { return nil }
        let previous = self.line(at: line.start - 1)
        guard isSplitLine(previous) else { return nil }
        if previous.start == 0 {
            return CueEdit(range: NSRange(location: 0, length: 2), insert: "", caret: 0)
        }
        return CueEdit(range: NSRange(location: previous.start - 1, length: 2), insert: "", caret: previous.start)
    }

    /// 块尾 Delete 对称合并：下一行是分隔线时整条删除，光标不动。
    public func mergeForward(selection: NSRange) -> CueEdit? {
        guard selection.length == 0 else { return nil }
        let line = line(at: selection.location)
        guard selection.location == line.end, line.end < length else { return nil }
        let next = self.line(at: line.end + 1)
        guard isSplitLine(next) else { return nil }
        return CueEdit(range: NSRange(location: line.end, length: 1 + next.end - next.start), insert: "", caret: line.end)
    }

    // MARK: 光标

    /// 空光标不允许落在分隔线行上（控件是原子的）：按移动方向整体跨到相邻行；
    /// 无处可去时保持原位。
    public func normalizedCaret(from old: Int, to new: Int) -> Int {
        let line = line(at: new)
        guard isSplitLine(line) else { return new }
        let hasNext = line.end < length
        if new >= old, hasNext { return line.end + 1 }
        if line.start > 0 { return line.start - 1 }
        return hasNext ? line.end + 1 : new
    }

    // MARK: 块

    /// 下一块首行位置；无处可跳返回 nil。分隔线行归属上一块：光标在分隔线上时，下一块就是其后第一行。
    public func nextBlockStart(from head: Int) -> Int? {
        let lines = allLines()
        let current = lineIndex(of: head, in: lines)
        guard let next = markerIndices(lines).first(where: { $0 >= current }), next < lines.count - 1 else { return nil }
        return lines[next + 1].start
    }

    /// 上一块首行位置：块内非首行先跳块首，已在块首再往上一块；无处可跳返回 nil。
    public func prevBlockStart(from head: Int) -> Int? {
        let lines = allLines()
        let current = lineIndex(of: head, in: lines)
        let before = markerIndices(lines).filter { $0 < current }
        let currentStart = (before.last ?? -1) + 1
        if current > currentStart { return lines[currentStart].start }
        guard before.count > 0 else { return nil }
        return lines[before.count >= 2 ? before[before.count - 2] + 1 : 0].start
    }

    /// `location` 所在块在 `CueSegments.parse` 结果里的下标。
    public func blockIndex(at location: Int) -> Int {
        let lines = allLines()
        let current = lineIndex(of: location, in: lines)
        return markerIndices(lines).filter { $0 < current }.count
    }

    /// 全部分隔线（升序）。
    public func dividers() -> [CueDivider] {
        let lines = allLines()
        var closed = 0
        var hasText = false
        var result: [CueDivider] = []
        for line in lines {
            if !isSplitLine(line) {
                if !isBlank(line) { hasText = true }
                continue
            }
            if hasText { closed += 1 }
            hasText = false
            result.append(CueDivider(location: line.start, blockIndex: result.count + 1, sequence: closed))
        }
        return result
    }

    private func markerIndices(_ lines: [Line]) -> [Int] {
        lines.indices.filter { isSplitLine(lines[$0]) }
    }

    private func lineIndex(of location: Int, in lines: [Line]) -> Int {
        lines.lastIndex { $0.start <= location } ?? 0
    }
}
