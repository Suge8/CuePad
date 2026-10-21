import Foundation
import Testing
import CueText

@Suite("存储格式")
struct CueFormatTests {
    let id = "48a0cc37d2d0f0a6"

    @Test("行内图片切成 token，其余（含分割线 ---、残缺的图片标记）原样是文字，序列化后与原文一致")
    func roundTrip() {
        let stored = "前文 ![](cuepad://img/\(id)) 后文\n---\n第二段\n![](cuepad://img/\(id))"
        let tokens = CueFormat.parse(stored)
        #expect(tokens == [.text("前文 "), .image(id), .text(" 后文\n---\n第二段\n"), .image(id)])
        #expect(CueFormat.serialize(tokens) == stored)

        let lookalikes = "![](cuepad://img/)\n![](cuepad://img/xyz)\n![](cuepad://img/ab"  // 残缺的图片标记都是普通文字
        #expect(CueFormat.parse(lookalikes) == [.text(lookalikes)])
    }
}

@Suite("标题与摘要")
struct CueSummaryTests {
    @Test("卡片标题与摘要：标题是首个标题行并去掉 # 前缀，摘要只取其后的第一段（到空行、分割线或只有图片的行为止）", arguments: [
        ("![](cuepad://img/ab)\n\n## 周报\n第二行 ![](cuepad://img/cd) 尾\n---\n第三行", "周报", "第二行 尾"),
        ("标题\n\n第一段一\n第一段二\n\n第二段", "标题", "第一段一 第一段二"),
        ("标题 ![](cuepad://img/ab) 续\n正文", "标题 续", "正文"),
        ("#无空格也去掉", "无空格也去掉", ""),
        ("C# 入门\n不是标题前缀", "C# 入门", "不是标题前缀"),
        ("---\n![](cuepad://img/ab)", "", ""),
        ("", "", ""),
        // 有文字的行只有一条规则：空白行、分割线、只有图片（存储格式或编辑器里的 U+FFFC）的行都不算
        ("   \n  周报  ", "周报", ""),
        ("![](cuepad://img/ab) ![](cuepad://img/cd)\n![](cuepad://img/ab) 说明", "说明", ""),
        ("\u{FFFC}\n\u{FFFC} 说明\n正文", "说明", "正文"),
    ])
    func summary(stored: String, title: String, preview: String) {
        let summary = CueSummary(stored)
        #expect(summary.title == title)
        #expect(summary.preview == preview)
    }

    @Test("变量：提取去重、按首次出现排，名称不含花括号与换行；填充替换所有出现，缺省与空串保留占位符")
    func variables() {
        #expect(CueVariables.names(in: "纯文本").isEmpty)
        #expect(CueVariables.names(in: "{{产品}} / {{语气}} / {{产品}}") == ["产品", "语气"])
        #expect(CueVariables.names(in: "{{}} {{a\nb}} {{{x}} {{y}}}") == ["x", "y"])
        #expect(CueVariables.fill("{{产品}}：{{语气}}；再次 {{产品}}", values: ["产品": "CuePad"]) == "CuePad：{{语气}}；再次 CuePad")
        #expect(CueVariables.fill("{{甲}}/{{乙}}", values: ["甲": "x", "乙": ""]) == "x/{{乙}}")
        #expect(CueVariables.fill("😀{{名}}😀", values: ["名": "值"]) == "😀值😀")
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
}
