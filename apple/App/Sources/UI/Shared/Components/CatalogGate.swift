import SwiftUI

/// 项目目录读到之前不显示页面（页面里的项目名称、计数从第一帧起就是真实值）；读取失败时说明原因并给"重试"。
/// 订阅由根视图以 `.task(id: workspace.catalogAttempt)` 启动。
struct CatalogGate<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if workspace.catalog != nil {
            // 任务编辑框需要常驻的宿主：任务菜单收起后，菜单所在的行就没了
            content.modifier(TaskEditor())
        } else if let failure = workspace.catalogFailure {
            ContentUnavailableView {
                Label("读不出资料库", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                let retry = Button("重试") { workspace.retryCatalog() }
                // iOS 的系统默认按钮没有外形，用与"新建项目"同一个主按钮；Mac 的系统按钮本身有外形
                #if os(iOS)
                retry.prominentButton().controlSize(.large).frame(minHeight: 44)
                #else
                retry
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.desk)
        } else {
            palette.desk.ignoresSafeArea()
        }
    }
}
