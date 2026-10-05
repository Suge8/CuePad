import Foundation
import Testing
@testable import CueText

/// 测试文档里 U+FFFC 一律代表分割线（图片与分割线的区分由 `imageAware` 单独覆盖）。
private let S = "\u{FFFC}"

private func buffer(_ text: String) -> CueBuffer {
    let ns = text as NSString
    return CueBuffer(text: ns) { ns.character(at: $0) == CueFormat.objectCharacter }
}

private func apply(_ edit: CueEdit, to text: String) -> String {
    (text as NSString).replacingCharacters(in: edit.range, with: edit.insert)
}

@Suite("插入分割线")
struct DividerEditTests {
    private func split(_ text: String, _ location: Int, _ length: Int = 0) -> (doc: String, tail: String) {
        let edit = buffer(text).dividerEdit(selection: NSRange(location: location, length: length))
        let doc = apply(edit, to: text)
        return (doc, (doc as NSString).substring(from: edit.caret))
    }

    @Test("行中插入：光标后内容到线下")
    func middle() {
        let r = split("abc", 1)
        #expect(r.doc == "a\n\(S)\nbc" && r.tail == "bc")
    }

    @Test("非空行行首插入：整行推到线下，不多插空行")
    func lineStart() {
        let r = split("abc", 0)
        #expect(r.doc == "\(S)\nabc" && r.tail == "abc")
    }

    @Test("空行上插入：整行变分割线，不残留空行")
    func blankLine() {
        let r = split("a\n\nb", 2)
        #expect(r.doc == "a\n\(S)\nb" && r.tail == "b")
    }

    @Test("文档尾插入：光标落在线下的新空行")
    func atEnd() {
        let r = split("a", 1)
        #expect(r.doc == "a\n\(S)\n" && r.tail == "")
        let blankTail = split("a\n", 2)
        #expect(blankTail.doc == "a\n\(S)\n" && blankTail.tail == "")
    }

    @Test("选区被分割线替换")
    func selection() {
        let r = split("abcdef", 1, 4)
        #expect(r.doc == "a\n\(S)\nf" && r.tail == "f")
    }
}

@Suite("删除分割线")
struct MergeEditTests {
    private let doc = "a\n\(S)\nb"

    @Test("线下行首 Backspace：删除整条分割线，保留一个换行，光标到这一行行首")
    func backward() throws {
        let edit = try #require(buffer(doc).mergeBackward(selection: NSRange(location: 4, length: 0)))
        #expect(apply(edit, to: doc) == "a\nb")
        #expect(edit.caret == 2)
    }

    @Test("分割线是文档首行：连同其换行一起删")
    func backwardAtHead() throws {
        let head = "\(S)\nb"
        let edit = try #require(buffer(head).mergeBackward(selection: NSRange(location: 2, length: 0)))
        #expect(apply(edit, to: head) == "b" && edit.caret == 0)
    }

    @Test("连续分割线一次只删最近一条")
    func backwardOne() throws {
        let multi = "a\n\(S)\n\(S)\nb"
        let edit = try #require(buffer(multi).mergeBackward(selection: NSRange(location: 6, length: 0)))
        #expect(apply(edit, to: multi) == "a\n\(S)\nb")
    }

    @Test("Backspace 回落默认：前一行不是分割线、光标不在行首、有选区")
    func backwardFallsBack() {
        #expect(buffer("a\nb").mergeBackward(selection: NSRange(location: 2, length: 0)) == nil)
        #expect(buffer(doc).mergeBackward(selection: NSRange(location: 5, length: 0)) == nil)
        #expect(buffer(doc).mergeBackward(selection: NSRange(location: 4, length: 1)) == nil)
    }

    @Test("线上行尾 Delete：删除整条分割线，光标不动")
    func forward() throws {
        let edit = try #require(buffer(doc).mergeForward(selection: NSRange(location: 1, length: 0)))
        #expect(apply(edit, to: doc) == "a\nb" && edit.caret == 1)
        let tail = "a\n\(S)"
        let tailEdit = try #require(buffer(tail).mergeForward(selection: NSRange(location: 1, length: 0)))
        #expect(apply(tailEdit, to: tail) == "a")
    }

    @Test("Delete 回落默认：下一行不是分割线、光标不在行尾")
    func forwardFallsBack() {
        #expect(buffer("a\nb").mergeForward(selection: NSRange(location: 1, length: 0)) == nil)
        #expect(buffer(doc).mergeForward(selection: NSRange(location: 0, length: 0)) == nil)
    }
}

@Suite("光标规范化")
struct CaretTests {
    // 位置：第一块 0…5，5 是换行，6 是分割线，7 是换行，8 空行，9… 第二块
    private let b = buffer("第一块内容\n\(S)\n\n第二块内容")

    @Test("向前移动跨过分割线行，向后移动同理")
    func crossesAtomically() {
        #expect(b.normalizedCaret(from: 5, to: 6) == 8)
        #expect(b.normalizedCaret(from: 8, to: 7) == 5)
        #expect(b.normalizedCaret(from: 5, to: 7) == 8)
    }

    @Test("不在分割线行的光标原样保留")
    func untouched() {
        #expect(b.normalizedCaret(from: 0, to: 3) == 3)
        #expect(b.normalizedCaret(from: 0, to: 8) == 8)
    }

    @Test("边界：分割线是首行则向后，是末行则向前，独占全文则原位")
    func edges() {
        #expect(buffer("\(S)\nb").normalizedCaret(from: 2, to: 0) == 2)
        #expect(buffer("a\n\(S)").normalizedCaret(from: 0, to: 2) == 1)
        #expect(buffer(S).normalizedCaret(from: 0, to: 0) == 0)
    }

    @Test("分割线与图片同为 U+FFFC，只有分割线行被跳过")
    func imageAware() {
        let ns = "a\n\u{FFFC}\n\u{FFFC}\nb" as NSString
        let b = CueBuffer(text: ns) { $0 == 4 }  // 只有 4 是分割线，2 是图片
        #expect(b.normalizedCaret(from: 0, to: 2) == 2)
        #expect(b.normalizedCaret(from: 3, to: 4) == 6)
    }
}
