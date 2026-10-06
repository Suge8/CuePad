import Testing
@testable import CuePad

/// Pi 回答的 Markdown 按块解析（iOS 会话页、Mac 会话详情共用）：表格、引用、分级标题、嵌套列表、分割线各成一块，行内语法留给渲染。
struct MarkdownBlockTests {
    @Test func 表格按对齐行解析_单元格保留行内语法_缺的格补空() {
        let source = "| 方案 | 延迟 | 说明 |\n|:---|---:|:-:|\n| `sort` 按首次加入 | 12 ms | **不建议** |\n| 只有一格 |"
        #expect(MarkdownBlock.parse(source) == [.table(MarkdownTable(
            alignments: [.leading, .trailing, .center],
            header: ["方案", "延迟", "说明"],
            rows: [["`sort` 按首次加入", "12 ms", "**不建议**"], ["只有一格", "", ""]]))])
    }

    @Test func 没有对齐行的竖线行照常是段落() {
        #expect(MarkdownBlock.parse("| 不是表格 |\n下一行") == [.paragraph("| 不是表格 |\n下一行")])
    }

    @Test func 引用_分级标题_嵌套列表_分割线() {
        let source = "## 结果\n> 注意：没测\n> 16 人以上\n1. 先合\n   - 补用例\n---\n正文"
        #expect(MarkdownBlock.parse(source) == [
            .heading(level: 2, text: "结果"),
            .quote("注意：没测\n16 人以上"),
            .item(marker: "1.", text: "先合", depth: 0),
            .item(marker: "•", text: "补用例", depth: 1),
            .rule,
            .paragraph("正文"),
        ])
    }
}
