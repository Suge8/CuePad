import Foundation
import Testing
@testable import CueText

/// 测试文档里 U+FFFC 一律代表分隔线（图片与分隔线的区分由 `imageAware` 单独覆盖）。
private let S = "\u{FFFC}"

private func buffer(_ text: String) -> CueBuffer {
    let ns = text as NSString
    return CueBuffer(text: ns) { ns.character(at: $0) == CueFormat.objectCharacter }
}

private func apply(_ edit: CueEdit, to text: String) -> String {
    (text as NSString).replacingCharacters(in: edit.range, with: edit.insert)
}

@Suite("Shift+Enter 切块")
struct SplitEditTests {
    private func split(_ text: String, _ location: Int, _ length: Int = 0) -> (doc: String, tail: String) {
        let edit = buffer(text).splitEdit(selection: NSRange(location: location, length: length))
        let doc = apply(edit, to: text)
        return (doc, (doc as NSString).substring(from: edit.caret))
    }

    @Test("行中切块：光标后内容成为新块开头")
    func middle() {
        let r = split("abc", 1)
        #expect(r.doc == "a\n\(S)\nbc" && r.tail == "bc")
    }

    @Test("非空行行首切块：整行推入新块，不多插空行")
    func lineStart() {
        let r = split("abc", 0)
        #expect(r.doc == "\(S)\nabc" && r.tail == "abc")
    }

    @Test("空行上切块：整行变分隔线，不残留空行")
    func blankLine() {
        let r = split("a\n\nb", 2)
        #expect(r.doc == "a\n\(S)\nb" && r.tail == "b")
    }

    @Test("文档尾切块：光标落在新空块")
    func atEnd() {
        let r = split("a", 1)
        #expect(r.doc == "a\n\(S)\n" && r.tail == "")
        let blankTail = split("a\n", 2)
        #expect(blankTail.doc == "a\n\(S)\n" && blankTail.tail == "")
    }

    @Test("选区被分隔线替换")
    func selection() {
        let r = split("abcdef", 1, 4)
        #expect(r.doc == "a\n\(S)\nf" && r.tail == "f")
    }
}

@Suite("合并块")
struct MergeEditTests {
    private let doc = "a\n\(S)\nb"

    @Test("块首 Backspace：删除整条分隔线，保留一个换行，光标到后一块块首")
    func backward() throws {
        let edit = try #require(buffer(doc).mergeBackward(selection: NSRange(location: 4, length: 0)))
        #expect(apply(edit, to: doc) == "a\nb")
        #expect(edit.caret == 2)
    }

    @Test("分隔线是文档首行：连同其换行一起删")
    func backwardAtHead() throws {
        let head = "\(S)\nb"
        let edit = try #require(buffer(head).mergeBackward(selection: NSRange(location: 2, length: 0)))
        #expect(apply(edit, to: head) == "b" && edit.caret == 0)
    }

    @Test("连续分隔线一次只删最近一条")
    func backwardOne() throws {
        let multi = "a\n\(S)\n\(S)\nb"
        let edit = try #require(buffer(multi).mergeBackward(selection: NSRange(location: 6, length: 0)))
        #expect(apply(edit, to: multi) == "a\n\(S)\nb")
    }

    @Test("Backspace 回落默认：前一行不是分隔线、光标不在行首、有选区")
    func backwardFallsBack() {
        #expect(buffer("a\nb").mergeBackward(selection: NSRange(location: 2, length: 0)) == nil)
        #expect(buffer(doc).mergeBackward(selection: NSRange(location: 5, length: 0)) == nil)
        #expect(buffer(doc).mergeBackward(selection: NSRange(location: 4, length: 1)) == nil)
    }

    @Test("块尾 Delete：删除整条分隔线，光标不动")
    func forward() throws {
        let edit = try #require(buffer(doc).mergeForward(selection: NSRange(location: 1, length: 0)))
        #expect(apply(edit, to: doc) == "a\nb" && edit.caret == 1)
        let tail = "a\n\(S)"
        let tailEdit = try #require(buffer(tail).mergeForward(selection: NSRange(location: 1, length: 0)))
        #expect(apply(tailEdit, to: tail) == "a")
    }

    @Test("Delete 回落默认：下一行不是分隔线、光标不在行尾")
    func forwardFallsBack() {
        #expect(buffer("a\nb").mergeForward(selection: NSRange(location: 1, length: 0)) == nil)
        #expect(buffer(doc).mergeForward(selection: NSRange(location: 0, length: 0)) == nil)
    }
}

@Suite("光标规范化")
struct CaretTests {
    // 位置：第一块 0…5，5 是换行，6 是分隔线，7 是换行，8 空行，9… 第二块
    private let b = buffer("第一块内容\n\(S)\n\n第二块内容")

    @Test("向前移动跨过分隔线行，向后移动同理")
    func crossesAtomically() {
        #expect(b.normalizedCaret(from: 5, to: 6) == 8)
        #expect(b.normalizedCaret(from: 8, to: 7) == 5)
        #expect(b.normalizedCaret(from: 5, to: 7) == 8)
    }

    @Test("不在分隔线行的光标原样保留")
    func untouched() {
        #expect(b.normalizedCaret(from: 0, to: 3) == 3)
        #expect(b.normalizedCaret(from: 0, to: 8) == 8)
    }

    @Test("边界：分隔线是首行则向后，是末行则向前，独占全文则原位")
    func edges() {
        #expect(buffer("\(S)\nb").normalizedCaret(from: 2, to: 0) == 2)
        #expect(buffer("a\n\(S)").normalizedCaret(from: 0, to: 2) == 1)
        #expect(buffer(S).normalizedCaret(from: 0, to: 0) == 0)
    }

    @Test("分隔线与图片同为 U+FFFC，只有分隔线行被跳过")
    func imageAware() {
        let ns = "a\n\u{FFFC}\n\u{FFFC}\nb" as NSString
        let b = CueBuffer(text: ns) { $0 == 4 }  // 只有 4 是分隔线，2 是图片
        #expect(b.normalizedCaret(from: 0, to: 2) == 2)
        #expect(b.normalizedCaret(from: 3, to: 4) == 6)
    }
}

@Suite("块导航")
struct BlockNavigationTests {
    private let doc = "第一块\n\(S)\n第二块首\n第二块尾\n\(S)\n第三块"
    // 偏移：第一块 0…3，S 4，第二块首 6…10，第二块尾 11…15，S 16，第三块 18…21

    @Test("块范围：首块、多行中间块、末块；分隔线行归上一块")
    func ranges() {
        let b = buffer(doc)
        #expect(b.blockRange(at: 0) == NSRange(location: 0, length: 3))
        #expect(b.blockRange(at: 8) == NSRange(location: 6, length: 9))
        #expect(b.blockRange(at: 19) == NSRange(location: 18, length: 3))
        #expect(b.blockRange(at: 4) == NSRange(location: 0, length: 3))
        #expect(buffer("a\nb").blockRange(at: 2) == NSRange(location: 0, length: 3))
    }

    @Test("块下标：分隔线行归上一块")
    func index() {
        let b = buffer(doc)
        #expect([0, 4, 6, 12, 16, 18].map { b.blockIndex(at: $0) } == [0, 0, 1, 1, 1, 2])
    }

    @Test("下一块：正文与分隔线行都指向紧随其后的块；末块返回 nil")
    func next() {
        let b = buffer(doc)
        #expect(b.nextBlockStart(from: 1) == 6)
        #expect(b.nextBlockStart(from: 8) == 18)
        #expect(b.nextBlockStart(from: 4) == 6)
        #expect(b.nextBlockStart(from: 19) == nil)
    }

    @Test("上一块：块内非首行先跳块首，块首再往上一块；首块块首返回 nil")
    func previous() {
        let b = buffer(doc)
        #expect(b.prevBlockStart(from: 12) == 6)
        #expect(b.prevBlockStart(from: 6) == 0)
        #expect(b.prevBlockStart(from: 0) == nil)
        #expect(b.prevBlockStart(from: 4) == 0)
        #expect(b.prevBlockStart(from: 16) == 6)
    }

    @Test("分隔线的块下标与编号序号：编号只数非空块")
    func dividers() {
        let b = buffer("\(S)\n甲\n\(S)\n\n\(S)\n乙")
        #expect(b.dividers() == [
            CueDivider(location: 0, blockIndex: 1, sequence: 0),
            CueDivider(location: 4, blockIndex: 2, sequence: 1),
            CueDivider(location: 7, blockIndex: 3, sequence: 1),
        ])
    }
}
