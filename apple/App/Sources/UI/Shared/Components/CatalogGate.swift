import SwiftUI

/// 资料库读不出来时（项目目录读取失败）盖住页面：给原因与"重试"。目录在建工作区时当场读到，没有"还没读到"这一态。
/// 一个窗口只挂一处、整窗一张（iOS 的根、Mac 主窗口的三栏外面，`MainWindow`）：挂在每一栏上时一屏并排几张一模一样的卡。
struct CatalogGate<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let failure = workspace.catalogFailure {
            UnreadableLibraryView(failure: LibraryFailure(reason: failure, location: workspace.services.location)) {
                workspace.retryCatalog()
            }
        } else {
            content
        }
    }
}
