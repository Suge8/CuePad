import Foundation
import Testing
@testable import CueText

/// 文档里 U+FFFC 一律代表分隔线。
private let S = "\u{FFFC}"

/// 存储格式转成运行时正文：分隔线与图片各占一个 U+FFFC，返回文本与分隔线偏移。
private func runtime(_ stored: String) -> (text: NSString, splits: Set<Int>) {
    var text = "", splits = Set<Int>()
    for token in CueFormat.parse(stored) {
        switch token {
        case .text(let s): text += s
        case .image: text += S
        case .split: splits.insert(text.utf16.count); text += S
        }
    }
    return (text as NSString, splits)
}

/// 编辑器里被当作标题的那一行（卡片标题与它是同一条规则，两处各有一份实现，所以两边都要对上字面值）。
@Suite("标题规则")
struct TitleRuleTests {
    @Test("编辑器的标题行与卡片标题一致：跳过空行、分隔线、只有图片的行", arguments: [
        ("\n\n周报\n正文", "周报"),
        ("![](cuepad://img/ab)\n标题", "标题"),
        ("---split---\n![](cuepad://img/ab) 说明\n后", "说明"),
        ("---split---\n \n![](cuepad://img/ab)![](cuepad://img/cd)\n真标题", "真标题"),
        ("![](cuepad://img/ab)\n---split---\n", ""),
        ("", ""),
    ])
    func titleLine(stored: String, expected: String) {
        let (text, splits) = runtime(stored)
        let d = CueDecorations(CueBuffer(text: text) { splits.contains($0) })
        #expect(CueLines.contentLines(stored).first ?? "" == expected)
        guard let location = d.titleLocation else { return #expect(expected.isEmpty) }
        let line = text.substring(with: NSRange(location: location, length: text.length - location)).components(separatedBy: "\n")[0]
        #expect(line.replacingOccurrences(of: S, with: "").trimmingCharacters(in: .whitespaces) == expected)
    }
}
