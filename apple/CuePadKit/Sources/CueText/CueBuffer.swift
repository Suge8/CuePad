import Foundation

/// 编辑器运行时正文的只读视图：UTF-16 文本里分割线和图片各占一个 U+FFFC，
/// 由宿主回答哪个位置是分割线。插入、删除分割线与光标跨线都是对它的纯函数，坐标为 UTF-16 偏移。
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
}

/// 一次文本替换加变更后的光标位置。`insert` 里的 U+FFFC 表示一条分割线。
public struct CueEdit: Equatable, Sendable {
    public var range: NSRange
    public var insert: String
    public var caret: Int
}

extension CueBuffer {
    private static let object = String(UnicodeScalar(CueFormat.objectCharacter)!)

    // MARK: 编辑

    /// 插入分割线：光标前内容留在上面，光标后内容到线下；选区被分割线替换；
    /// 光标在空行上时整行变分割线，不残留多余空行。
    public func dividerEdit(selection: NSRange) -> CueEdit {
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

    /// 行首 Backspace：前一行是分割线时整条删除（保留一个换行）；否则 nil，回落默认行为。
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

    /// 行尾 Delete 对称：下一行是分割线时整条删除，光标不动。
    public func mergeForward(selection: NSRange) -> CueEdit? {
        guard selection.length == 0 else { return nil }
        let line = line(at: selection.location)
        guard selection.location == line.end, line.end < length else { return nil }
        let next = self.line(at: line.end + 1)
        guard isSplitLine(next) else { return nil }
        return CueEdit(range: NSRange(location: line.end, length: 1 + next.end - next.start), insert: "", caret: line.end)
    }

    // MARK: 光标

    /// 空光标不允许落在分割线行上（分割线是一个整体）：按移动方向整体跨到相邻行；
    /// 无处可去时保持原位。
    public func normalizedCaret(from old: Int, to new: Int) -> Int {
        let line = line(at: new)
        guard isSplitLine(line) else { return new }
        let hasNext = line.end < length
        if new >= old, hasNext { return line.end + 1 }
        if line.start > 0 { return line.start - 1 }
        return hasNext ? line.end + 1 : new
    }
}
