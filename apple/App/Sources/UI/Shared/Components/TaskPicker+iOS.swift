#if os(iOS)
import SwiftUI

extension TaskPicker {
    var content: some View {
        NavigationStack {
            List {
                Section { newTask.listRowBackground(palette.paper) }
                ForEach(shown, id: \.projectID) { group in
                    Section {
                        ForEach(group.tasks) { task in row(task).listRowBackground(palette.paper) }
                    } header: {
                        header(group.projectID)
                    }
                }
                if groups?.isEmpty == true {
                    Text(Self.empty).foregroundStyle(palette.ink3).listRowBackground(Color.clear)
                }
            }
            .listSectionSpacing(.compact)
            // 搜索框下面直接是"新建任务…"，不留分组默认的一大段上边距
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(palette.desk)
            .navigationTitle("挂到任务")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { close() } }
            }
            // 列表滚到屏幕下沿时在主屏指示条那一段淡出，不被圆角硬裁（同任务浮窗）
            .fadesUnderBars()
        }
        // 一开就满高，同任务浮窗：不满高的系统浮窗是悬空的，下沿圆角会切掉最后一行、露出背后的纸页
        .presentationDetents([.large])
    }
}
#endif
