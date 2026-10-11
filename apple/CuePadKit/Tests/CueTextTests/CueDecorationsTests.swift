import Foundation
import Testing
@testable import CueText

/// 文档里 U+FFFC 一律代表分隔线。
private let S = "\u{FFFC}"

private func styles(_ text: String) -> [CueLineStyle] {
    let ns = text as NSString
    let d = CueDecorations(CueBuffer(text: ns) { ns.character(at: $0) == CueFormat.objectCharacter })
    var location = 0
    return text.components(separatedBy: "\n").map { line in
        defer { location += line.utf16.count + 1 }
        return d.style(ofLine: line, at: location)
    }
}

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

@Suite("编辑器装饰")
struct DecorationRuleTests {
    @Test("编辑器的标题行就是 CueLines.contentLines 的第一行（标题规则只有一条）", arguments: [
        "\n\n周报\n正文",
        "![](cuepad://img/ab)\n标题",
        "---split---\n![](cuepad://img/ab) 说明\n后",
        "---split---\n \n![](cuepad://img/ab)![](cuepad://img/cd)\n真标题",
        "![](cuepad://img/ab)\n---split---\n",
        "",
    ])
    func titleIsTheFirstContentLine(stored: String) {
        let (text, splits) = runtime(stored)
        let d = CueDecorations(CueBuffer(text: text) { splits.contains($0) })
        let expected = CueLines.contentLines(stored).first ?? ""
        guard let location = d.titleLocation else { return #expect(expected.isEmpty) }
        let line = text.substring(with: NSRange(location: location, length: text.length - location)).components(separatedBy: "\n")[0]
        #expect(line.replacingOccurrences(of: S, with: "").trimmingCharacters(in: .whitespaces) == expected)
    }

    @Test("行样式：标题 1–6 个 # 加空白、列表允许缩进、围栏必须顶格且未闭合到文末、围栏内与不成对的反引号不算行内 code")
    func lineStyles() {
        let s = styles("# a\n###### b\n####### c\n##d\n- a\n  - b\n-c\n1. d\n1.f")
        #expect(s.map(\.kind) == [.heading, .heading, .body, .body, .list, .list, .body, .list, .body])
        let fences = styles("前\n```swift\n# 不是标题\n- 不是列表\n```\n后\n```\n没闭合\n  ```")
        #expect(fences.map(\.kind) == [.body, .fence, .code, .code, .fence, .body, .fence, .code, .code])
        let code = styles("运行 `swift test` 与 `x` 后\n`未闭合")
        #expect(code[0].inlineCode == [NSRange(location: 3, length: 12), NSRange(location: 18, length: 3)] && code[1].inlineCode.isEmpty)
    }
}
