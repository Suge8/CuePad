import Foundation
import Testing
@testable import CueText

@Suite("存储格式")
struct CueFormatTests {
    let id = "48a0cc37d2d0f0a6"

    @Test("分隔线与行内图片解析成 token，序列化后与原文一致")
    func roundTrip() {
        let stored = "前文 ![](cuepad://img/\(id)) 后文\n---split---\n第二块\n![](cuepad://img/\(id))"
        let tokens = CueFormat.parse(stored)
        #expect(tokens == [
            .text("前文 "), .image(id), .text(" 后文"), .text("\n"), .split, .text("\n"),
            .text("第二块"), .text("\n"), .image(id),
        ])
        #expect(CueFormat.serialize(tokens) == stored)
    }

    @Test("历史角色标记按分隔线解析，保存时归一化为 ---split---")
    func legacyMarkers() {
        let tokens = CueFormat.parse("背景\n---ask---\n问题\n  ---answer---\t\n回答\n---system---")
        #expect(tokens.filter { $0 == .split }.count == 3)
        #expect(CueFormat.serialize(tokens) == "背景\n---split---\n问题\n---split---\n回答\n---split---")
    }

    @Test("非独占行或形近的分隔标记、残缺的图片标记都是普通文字")
    func lookalikesStayText() {
        let stored = "前缀 ---split---\n---split--- 后缀\n----split----\n![](cuepad://img/)\n![](cuepad://img/xyz)\n![](cuepad://img/ab"
        #expect(CueFormat.parse(stored).allSatisfy { if case .text = $0 { true } else { false } })
        #expect(CueFormat.serialize(CueFormat.parse(stored)) == stored)
    }

    @Test("CRLF 换行的分隔线行也被识别")
    func crlf() {
        #expect(CueFormat.parse("a\r\n---split---\r\nb").contains(.split))
    }
}

@Suite("分段与复制排版")
struct CueSegmentsTests {
    private func texts(_ stored: String) -> [String] { CueSegments.parse(stored).map(\.text) }
    private let split = CueFormat.splitMarker

    @Test("无分隔线整篇一段并逐字保留；空文本得到一个空段")
    func single() {
        let text = "第一行\n\n  缩进行\t\n结尾"
        #expect(texts(text) == [text])
        #expect(texts("") == [""])
    }

    @Test("多个分隔线依次切分，分隔线行带空白仍算分隔")
    func splitting() {
        #expect(texts("a\n\(split)\nb\n  \(split)\t \nc") == ["a", "b", "c"])
        #expect(texts("\(split)\n正文\n\(split)") == ["", "正文", ""])
    }

    @Test("非独占行、形近的标记不误切；段内空行与行尾空格保留")
    func notSplit() {
        let inline = "前缀 \(split)\n\(split) 后缀\nx\(split)x\n----split----\n---SPLIT---"
        #expect(texts(inline) == [inline])
        #expect(texts("开头\n\n  中间  \n\n\(split)\n\n结尾") == ["开头\n\n  中间  \n", "\n结尾"])
    }

    @Test("历史角色标记按分隔线切分")
    func legacy() {
        #expect(texts("背景\n---ask---\n问题\n---answer---\n回答") == ["背景", "问题", "回答"])
        #expect(texts("---system---\n你是助手\n\(split)\n正文") == ["", "你是助手", "正文"])
    }

    @Test("编号标签", arguments: [
        (CueNumbering.decimal, 0, "1"), (.alpha, 0, "A"), (.alpha, 25, "Z"), (.alpha, 26, "AA"),
        (.cjk, 0, "一"), (.cjk, 9, "十"), (.cjk, 11, "十二"), (.cjk, 20, "二十一"), (.cjk, 98, "九十九"), (.cjk, 99, "100"), (.none, 0, ""),
    ])
    func labels(numbering: CueNumbering, index: Int, expected: String) {
        #expect(numbering.label(forSegment: index) == expected)
    }

    @Test("卡片标题只有一条规则：非空、不是分隔线、除图片外还有文字")
    func titleLine() {
        let cases: [(String, Bool)] = [
            ("周报", true), ("  周报  ", true), ("", false), ("   ", false),
            ("---split---", false), ("---ask---", false),
            ("![](cuepad://img/ab)", false), ("![](cuepad://img/ab) ![](cuepad://img/cd)", false),
            ("![](cuepad://img/ab) 说明", true), ("\u{FFFC}", false), ("\u{FFFC} 说明", true),
        ]
        for (line, expected) in cases { #expect(CueSegments.isTitleLine(line) == expected, "\(line.debugDescription)") }
    }

    @Test("卡片标题与摘要：标题是首个标题行并去掉 # 前缀，摘要是其后各标题行以空格连接", arguments: [
        ("![](cuepad://img/ab)\n\n## 周报\n第二行 ![](cuepad://img/cd) 尾\n---split---\n第三行", "周报", "第二行 尾 第三行"),
        ("标题 ![](cuepad://img/ab) 续\n正文", "标题 续", "正文"),
        ("#无空格也去掉", "无空格也去掉", ""),
        ("C# 入门\n不是标题前缀", "C# 入门", "不是标题前缀"),
        ("---split---\n![](cuepad://img/ab)", "", ""),
        ("", "", ""),
    ])
    func summary(stored: String, title: String, preview: String) {
        let summary = CueSummary(stored)
        #expect(summary.title == title)
        #expect(summary.preview == preview)
    }

    @Test("摘要最多 240 字")
    func previewLimit() {
        #expect(CueSummary("标题\n" + String(repeating: "长", count: 500)).preview.count == 240)
    }

    @Test("标题行文字：去掉图片引用，空白折成单个空格，跳过空行、分隔线、只有图片的行")
    func contentLines() {
        #expect(CueSegments.contentLines("a ![](cuepad://img/ab) b\n\n![](cuepad://img/cd)\n---split---\n  第三行  \n") == ["a b", "第三行"])
        #expect(CueSegments.contentLines("---ask---\n问题正文") == ["问题正文"])
        #expect(CueSegments.contentLines("\n\(split)\n\n正文") == ["正文"])
        #expect(CueSegments.contentLines("![](cuepad://img/ab)\n\n  周报 ![](cuepad://img/cd)  \n正文") == ["周报", "正文"])
        #expect(CueSegments.contentLines("---ask---\n\n").isEmpty)
        #expect(CueSegments.contentLines("![](cuepad://img/ab)").isEmpty)
        #expect(CueSegments.contentLines("").isEmpty)
    }

    @Test("trim 去首尾空行，保留段内空行与缩进")
    func trim() {
        #expect(CueSegments.trim("\n\n  a\n\n  b  \n\n") == "a\n\n  b")
    }

    @Test("复制排版", arguments: [
        ("\n正文\n\n", CueNumbering.decimal, "正文"),
        ("\n---split---\n  \n", .decimal, ""),
        ("a\n---split---\nb", .decimal, "## 1\na\n\n## 2\nb"),
        ("a\n---split---\nb", .alpha, "## A\na\n\n## B\nb"),
        ("a\n---split---\nb", .none, "a\n\n---\n\nb"),
        ("---ask---\n问一\n---answer---\n答一", .none, "问一\n\n---\n\n答一"),
        ("---ask---\n问一\n---answer---\n答一", .decimal, "## 1\n问一\n\n## 2\n答一"),
    ])
    func format(stored: String, numbering: CueNumbering, expected: String) {
        #expect(CueSegments.format(stored, numbering: numbering) == expected)
    }
}

@Suite("变量")
struct CueVariablesTests {
    @Test("提取变量名：去重、保留首次出现顺序；名称不含花括号与换行")
    func names() {
        #expect(CueVariables.names(in: "纯文本").isEmpty)
        #expect(CueVariables.names(in: "{{产品}} / {{语气}} / {{产品}}") == ["产品", "语气"])
        #expect(CueVariables.names(in: "{{}} {{a\nb}} {{{x}} {{y}}}") == ["x", "y"])
    }

    @Test("填充：已填替换所有出现，缺省与空串保留占位符")
    func fill() {
        #expect(CueVariables.fill("{{产品}}：{{语气}}；再次 {{产品}}", values: ["产品": "CuePad"]) == "CuePad：{{语气}}；再次 CuePad")
        #expect(CueVariables.fill("{{甲}}/{{乙}}", values: ["甲": "x", "乙": ""]) == "x/{{乙}}")
        #expect(CueVariables.fill("😀{{名}}😀", values: ["名": "值"]) == "😀值😀")
    }

    @Test("变量范围按 UTF-16 偏移，只返回指定范围内的")
    func ranges() {
        let text = "😀{{甲}} 中 {{乙}}"
        #expect(CueVariables.ranges(in: text, within: NSRange(location: 0, length: text.utf16.count)) == [NSRange(location: 2, length: 5), NSRange(location: 10, length: 5)])
        #expect(CueVariables.ranges(in: text, within: NSRange(location: 8, length: 7)) == [NSRange(location: 10, length: 5)])
    }
}
