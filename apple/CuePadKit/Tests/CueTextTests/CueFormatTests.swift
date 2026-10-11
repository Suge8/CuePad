import Foundation
import Testing
@testable import CueText

@Suite("存储格式")
struct CueFormatTests {
    let id = "48a0cc37d2d0f0a6"

    @Test("分隔线与行内图片解析成 token，序列化后与原文一致")
    func roundTrip() {
        let stored = "前文 ![](cuepad://img/\(id)) 后文\n---split---\n第二段\n![](cuepad://img/\(id))"
        let tokens = CueFormat.parse(stored)
        #expect(tokens == [
            .text("前文 "), .image(id), .text(" 后文"), .text("\n"), .split, .text("\n"),
            .text("第二段"), .text("\n"), .image(id),
        ])
        #expect(CueFormat.serialize(tokens) == stored)
    }

    @Test("非独占行或形近的分隔标记、残缺的图片标记都是普通文字")
    func lookalikesStayText() {
        let stored = "前缀 ---split---\n---split--- 后缀\n----split----\n![](cuepad://img/)\n![](cuepad://img/xyz)\n![](cuepad://img/ab"
        #expect(CueFormat.parse(stored).allSatisfy { if case .text = $0 { true } else { false } })
        #expect(CueFormat.serialize(CueFormat.parse(stored)) == stored)
    }

}

@Suite("标题与摘要")
struct CueSummaryTests {
    private let split = CueFormat.splitMarker

    @Test("卡片标题只有一条规则：非空、不是分隔线、除图片外还有文字")
    func titleLine() {
        let cases: [(String, Bool)] = [
            ("周报", true), ("  周报  ", true), ("", false), ("   ", false),
            ("---split---", false),
            ("![](cuepad://img/ab)", false), ("![](cuepad://img/ab) ![](cuepad://img/cd)", false),
            ("![](cuepad://img/ab) 说明", true), ("\u{FFFC}", false), ("\u{FFFC} 说明", true),
        ]
        for (line, expected) in cases { #expect(CueLines.isTitleLine(line) == expected, "\(line.debugDescription)") }
    }

    @Test("卡片标题与摘要：标题是首个标题行并去掉 # 前缀，摘要只取其后的第一段（到空行、分割线或只有图片的行为止）", arguments: [
        ("![](cuepad://img/ab)\n\n## 周报\n第二行 ![](cuepad://img/cd) 尾\n---split---\n第三行", "周报", "第二行 尾"),
        ("标题\n\n第一段一\n第一段二\n\n第二段", "标题", "第一段一 第一段二"),
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

    @Test("正文里第一个链接的域名（去掉 www.），卡片上当小标")
    func linkHost() {
        #expect(CueSummary("看这个 https://www.github.com/sugeh/cuepad/pull/3 再说").linkHost == "github.com")
        #expect(CueSummary("标题\n第二段 http://news.ycombinator.com/item?id=1").linkHost == "news.ycombinator.com")
        #expect(CueSummary("没有链接，只有 cuepad://img/ab").linkHost == nil)
    }

    @Test("搜索结果的摘要从命中处往前留一点截取，前面写省略号；命中在开头附近或在标题里时就是普通摘要")
    func snippet() {
        let body = "标题\n" + String(repeating: "铺垫", count: 30) + "这里有重连的问题"
        let hit = CueSummary.snippet(body, matching: ["重连"])
        #expect(hit.hasPrefix("…") && hit.contains("重连"))
        #expect(hit.distance(from: hit.startIndex, to: hit.range(of: "重连")!.lowerBound) <= CueSummary.snippetLead + 1)
        #expect(CueSummary.snippet("标题\n重连在开头", matching: ["重连"]) == "重连在开头")
        #expect(CueSummary.snippet("重连在标题\n正文", matching: ["重连"]) == "正文")
        #expect(CueSummary.snippet(body, matching: ["CHONG"]) == CueSummary(body).preview)
    }

    @Test("标题行文字：去掉图片引用，空白折成单个空格，跳过空行、分隔线、只有图片的行")
    func contentLines() {
        #expect(CueLines.contentLines("a ![](cuepad://img/ab) b\n\n![](cuepad://img/cd)\n---split---\n  第三行  \n") == ["a b", "第三行"])
        #expect(CueLines.contentLines("\n\(split)\n\n正文") == ["正文"])
        #expect(CueLines.contentLines("![](cuepad://img/ab)\n\n  周报 ![](cuepad://img/cd)  \n正文") == ["周报", "正文"])
        #expect(CueLines.contentLines("![](cuepad://img/ab)").isEmpty)
        #expect(CueLines.contentLines("").isEmpty)
    }

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

}
