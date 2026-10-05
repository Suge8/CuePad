import Foundation
import Testing
@testable import CueText

/// 文档里 U+FFFC 一律代表分隔线。
private let S = "\u{FFFC}"

private func decorations(_ text: String) -> CueDecorations {
    let ns = text as NSString
    return CueDecorations(CueBuffer(text: ns) { ns.character(at: $0) == CueFormat.objectCharacter })
}

/// 按行取样式：行号 0 起，行内容不含换行。
private func styles(_ text: String) -> [CueLineStyle] {
    let d = decorations(text)
    var location = 0
    return text.components(separatedBy: "\n").map { line in
        defer { location += line.utf16.count + 1 }
        return d.style(ofLine: line, at: location)
    }
}

@Suite("标题行")
struct TitleTests {
    @Test("标题是首个非空、非分隔线的行，前面的空行与分隔线不算")
    func firstNonBlankLine() {
        let text = "\n  \n\(S)\n\n周报\n正文"
        #expect(decorations(text).titleLocation == (text as NSString).range(of: "周报").location)
        #expect(styles(text).map(\.isTitle) == [false, false, false, false, true, false])
    }

    @Test("只有图片的行不能当标题，标题顺延到下一个有文字的行")
    func imageOnlyLineIsSkipped() {
        let ns = "\u{FFFC}\n\u{FFFC}\n标题" as NSString
        let d = CueDecorations(CueBuffer(text: ns) { _ in false })
        #expect(d.titleLocation == 4)
    }

    @Test("没有正文行时没有标题")
    func noTitle() {
        #expect(decorations("").titleLocation == nil)
        #expect(decorations("\n \n\(S)\n").titleLocation == nil)
    }

    @Test("标题行同时是 ## 标题时两个属性都保留")
    func titleAndHeading() {
        let s = styles("## 周报")[0]
        #expect(s.isTitle && s.kind == .heading && s.markerLength == 3)
    }
}

@Suite("标题规则唯一")
struct TitleRuleTests {
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

    @Test("编辑器的标题行就是 CueLines.contentLines 的第一行", arguments: [
        "\n\n周报\n正文",
        "![](cuepad://img/ab)\n标题",
        "---split---\n![](cuepad://img/ab) 说明\n后",
        "---ask---\n \n![](cuepad://img/ab)![](cuepad://img/cd)\n真标题",
        "![](cuepad://img/ab)\n---split---\n",
        "",
    ])
    func sameRule(stored: String) {
        let (text, splits) = runtime(stored)
        let d = CueDecorations(CueBuffer(text: text) { splits.contains($0) })
        let expected = CueLines.contentLines(stored).first ?? ""
        guard let location = d.titleLocation else { return #expect(expected.isEmpty) }
        let line = text.substring(with: NSRange(location: location, length: text.length - location)).components(separatedBy: "\n")[0]
        #expect(line.replacingOccurrences(of: S, with: "").trimmingCharacters(in: .whitespaces) == expected)
    }
}

@Suite("行样式")
struct LineStyleTests {
    @Test("标题 1–6 个 # 加空白；7 个或没有空白不是标题；标记长度含空白")
    func headings() {
        let s = styles("# a\n###### b\n####### c\n##d\n##\ttab")
        #expect(s.map(\.kind) == [.heading, .heading, .body, .body, .heading])
        #expect(s.map(\.markerLength) == [2, 7, 0, 0, 3])
    }

    @Test("无序与有序列表，允许缩进；标记长度含缩进")
    func lists() {
        let s = styles("- a\n  - b\n-c\n1. d\n  12. e\n1.f\n- ")
        #expect(s.map(\.kind) == [.list, .list, .body, .list, .list, .body, .list])
        #expect(s.map(\.markerLength) == [2, 4, 0, 3, 6, 0, 2])
    }

    @Test("围栏行与围栏内各行都是代码；未闭合的围栏一直到文末")
    func fences() {
        let s = styles("前\n```swift\n# 不是标题\n- 不是列表\n```\n后\n```\n没闭合")
        #expect(s.map(\.kind) == [.body, .fence, .code, .code, .fence, .body, .fence, .code])
        #expect(s[1].markerLength == "```swift".utf16.count)
    }

    @Test("围栏必须顶格；缩进的 ``` 不是围栏")
    func indentedFenceIsText() {
        #expect(styles("  ```\n正文").map(\.kind) == [.body, .body])
        #expect(decorations("  ```\n正文").fenceCount == 0)
    }

    @Test("围栏数量：文首的围栏也计入")
    func fenceCount() {
        #expect(decorations("```\na\n```\nb\n```").fenceCount == 3)
    }

    @Test("行内 code：成对反引号，含反引号本身；围栏内与不成对的不算")
    func inlineCode() {
        let s = styles("运行 `swift test` 与 `x` 后\n`未闭合\n``` \n`在围栏内`")
        #expect(s[0].inlineCode == [NSRange(location: 3, length: 12), NSRange(location: 18, length: 3)])
        #expect(s[1].inlineCode.isEmpty)
        #expect(s[3].inlineCode.isEmpty)
    }

    @Test("标题与列表行里的行内 code 也识别")
    func inlineCodeInBlocks() {
        #expect(styles("## 用 `foo`")[0].inlineCode == [NSRange(location: 5, length: 5)])
        #expect(styles("- 用 `foo`")[0].inlineCode == [NSRange(location: 4, length: 5)])
    }

    @Test("普通行没有任何装饰")
    func plain() {
        #expect(styles("普通一行 - 中间的 - 不算")[0] == CueLineStyle(kind: .body, isTitle: true, markerLength: 0, inlineCode: []))
    }
}
