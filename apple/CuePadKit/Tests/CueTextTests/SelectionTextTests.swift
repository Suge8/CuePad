import Foundation
import Testing
import CueText

/// 选区操作用到的纯文本规则：转为任务按行切。
@Suite("选区与发出的正文")
struct SelectionTextTests {
    @Test("转为任务：每行一个，去掉列表符号、复选框、图片与首尾空白，跳过空行和分割线")
    func taskLines() {
        let stored = "- 第一件\n\n2. 第二件 ![](cuepad://img/ab12)\n---\n  [ ] 第三件  \n* 第四件\n• 第五件\n![](cuepad://img/cd34)"
        #expect(CueLines.taskLines(stored) == ["第一件", "第二件", "第三件", "第四件", "第五件"])
    }
}
