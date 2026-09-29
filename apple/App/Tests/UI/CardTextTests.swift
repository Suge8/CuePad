import Testing
@testable import CuePad

/// 卡片标题只有 CueSegments 一条规则：CardText 与编辑器标题行同源。
struct CardTextTests {
    @Test("标题取首个有文字的行（跳过图片行、分隔线、空行）并去掉 # 前缀，摘要是其后各行")
    func titleAndPreview() {
        let text = CardText("![](cuepad://img/ab)\n\n## 周报\n第二行 ![](cuepad://img/cd) 尾\n---split---\n第三行")
        #expect(text.title == "周报")
        #expect(text.preview == "第二行 尾 第三行")
        #expect(text.images == ["ab", "cd"])
        #expect(text.blockCount == 2)
    }

    @Test("行内图片不截断标题：图片前后的文字仍是同一行")
    func inlineImage() {
        #expect(CardText("标题 ![](cuepad://img/ab) 续\n正文").title == "标题 续")
    }

    @Test("只有图片时没有标题")
    func imageOnly() {
        #expect(CardText("![](cuepad://img/ab)").title == "")
    }
}
