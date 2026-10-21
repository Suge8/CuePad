import SwiftUI

/// 待办、推进中、已完成一列的那张纸：行是全 App 那一种任务行（`TaskLine`，上级收成一行、状态看此刻干活的叶子），没绑任务的活会话是同一个语法的会话行
/// （`BoardSessionLine`）。一列一张，读着是一份清单：所在项目写在每行行尾（`BoardLook.project`），不按项目分段。
/// 分成几组时（推进中按档，`Workspace.byAttention`）组与组之间只留一点空，不写组名（界面不解释分组依据）。
struct BoardPaper<Row: Identifiable, Content: View>: View {
    let groups: [[Row]]
    @ViewBuilder let content: (Row) -> Content

    init(rows: [Row], @ViewBuilder content: @escaping (Row) -> Content) {
        self.init(groups: [rows], content: content)
    }

    init(groups: [[Row]], @ViewBuilder content: @escaping (Row) -> Content) {
        self.groups = groups.filter { !$0.isEmpty }
        self.content = content
    }

    var body: some View {
        if !groups.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups.indices, id: \.self) { index in
                    if index > 0 { Color.clear.frame(height: Self.groupGap) }
                    ForEach(groups[index]) { content($0) }
                }
            }
            .padding(Self.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: TaskMetrics.cardRadius)
        }
    }

    private static var groupGap: CGFloat { 10 }

    /// 纸的内边距：手机的行没有左右内边距（圈那一列自带点按宽），右边留一点，行尾的图标不贴边。
    private static var inset: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 4, leading: 14, bottom: 6, trailing: 14)
        #else
        EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 10)
        #endif
    }
}
