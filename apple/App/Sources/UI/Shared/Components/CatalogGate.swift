import SwiftUI

/// 项目目录读到之前不显示页面（页面里的项目名称、计数从第一帧起就是真实值）；读取失败时说明原因并给"重试"。
/// 订阅由根视图以 `.task(id: workspace.catalogAttempt)` 启动。
struct CatalogGate<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if workspace.catalog != nil {
            content
        } else if let failure = workspace.catalogFailure {
            ContentUnavailableView {
                Label("读不出资料库", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("重试") { workspace.retryCatalog() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.desk)
        } else {
            palette.desk.ignoresSafeArea()
        }
    }
}
