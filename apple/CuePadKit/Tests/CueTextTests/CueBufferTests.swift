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

/// 分割线的编辑规则（编辑器的按键与工具栏都经它；编辑器测试只验证接线）。期望值是用户看到的文档。
@Suite("分割线编辑")
struct DividerEditTests {
    @Test("插入：行首不多插空行，空行变分割线，文档尾落在线下新空行，选区被替换", arguments: [
        ("abc", 0, 0, "\(S)\nabc", "abc"),
        ("a\n\nb", 2, 0, "a\n\(S)\nb", "b"),
        ("a", 1, 0, "a\n\(S)\n", ""),
        ("a\n", 2, 0, "a\n\(S)\n", ""),
        ("abcdef", 1, 4, "a\n\(S)\nf", "f"),
    ])
    func insert(text: String, location: Int, length: Int, doc: String, tail: String) {
        let edit = buffer(text).dividerEdit(selection: NSRange(location: location, length: length))
        let result = apply(edit, to: text)
        #expect(result == doc && (result as NSString).substring(from: edit.caret) == tail)
    }

    @Test("Backspace / Delete 整条删掉分割线（文档首行连同换行；连续分割线一次一条），别处回落默认")
    func merge() throws {
        let doc = "a\n\(S)\nb"
        let back = try #require(buffer(doc).mergeBackward(selection: NSRange(location: 4, length: 0)))
        #expect(apply(back, to: doc) == "a\nb" && back.caret == 2)
        let head = "\(S)\nb"
        let first = try #require(buffer(head).mergeBackward(selection: NSRange(location: 2, length: 0)))
        #expect(apply(first, to: head) == "b" && first.caret == 0)
        let multi = "a\n\(S)\n\(S)\nb"
        let one = try #require(buffer(multi).mergeBackward(selection: NSRange(location: 6, length: 0)))
        #expect(apply(one, to: multi) == "a\n\(S)\nb")
        let forward = try #require(buffer(doc).mergeForward(selection: NSRange(location: 1, length: 0)))
        #expect(apply(forward, to: doc) == "a\nb" && forward.caret == 1)

        #expect(buffer("a\nb").mergeBackward(selection: NSRange(location: 2, length: 0)) == nil)
        #expect(buffer(doc).mergeBackward(selection: NSRange(location: 4, length: 1)) == nil)
        #expect(buffer(doc).mergeForward(selection: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("光标不落在分割线行上：首行、末行、独占全文时原位，图片与分割线同为 U+FFFC 但只跳分割线")
    func caret() {
        #expect(buffer("\(S)\nb").normalizedCaret(from: 2, to: 0) == 2)
        #expect(buffer("a\n\(S)").normalizedCaret(from: 0, to: 2) == 1)
        #expect(buffer(S).normalizedCaret(from: 0, to: 0) == 0)
        let ns = "a\n\u{FFFC}\n\u{FFFC}\nb" as NSString
        let imageAware = CueBuffer(text: ns) { $0 == 4 }  // 只有 4 是分割线，2 是图片
        #expect(imageAware.normalizedCaret(from: 0, to: 2) == 2)
        #expect(imageAware.normalizedCaret(from: 3, to: 4) == 6)
    }
}
