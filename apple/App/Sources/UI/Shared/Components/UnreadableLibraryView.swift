import SwiftUI

/// "读不出资料库"页（启动时库打不开、目录读取失败共用）：人话说明、折叠的原文、重试、导出诊断（复制到剪贴板）。
/// 没有任何写入入口：库没读出来，这时写进去的东西没有可靠的去处。
struct UnreadableLibraryView: View {
    let failure: LibraryFailure
    let retry: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        EmptyState(mascot: .error, title: "读不出资料库", message: failure.summary) {
            VStack(spacing: 16) {
                DisclosureGroup("详情") {
                    Text(failure.reason).font(.caption.monospaced()).textSelection(.enabled)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote).frame(maxWidth: 420)
                // iOS 的系统默认按钮没有外形，用与"新建项目"同一个主按钮；Mac 的系统按钮本身有外形
                #if os(iOS)
                EmptyStateButton(title: "重试", systemImage: "arrow.clockwise", action: retry)
                ExportDiagnosticsButton(text: failure.diagnostics).controlSize(.large).frame(minHeight: 44)
                #else
                HStack {
                    EmptyStateButton(title: "重试", systemImage: "arrow.clockwise", kind: .small, action: retry)
                    ExportDiagnosticsButton(text: failure.diagnostics)
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
    }
}
