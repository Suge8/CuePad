import SwiftUI

/// "读不出资料库"页（启动时库打不开、目录读取失败共用）：人话说明、折叠的原文、重试、导出诊断（复制到剪贴板）。
/// 没有任何写入入口：库没读出来，这时写进去的东西没有可靠的去处。
struct UnreadableLibraryView: View {
    let failure: LibraryFailure
    let retry: () -> Void
    @Environment(\.palette) private var palette
    @State private var copied = false

    var body: some View {
        ContentUnavailableView {
            Label("读不出资料库", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text(failure.summary)
                DisclosureGroup("详情") {
                    Text(failure.reason).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
            .frame(maxWidth: 420)
        } actions: {
            // iOS 的系统默认按钮没有外形，用与"新建项目"同一个主按钮；Mac 的系统按钮本身有外形
            #if os(iOS)
            Button("重试", action: retry).prominentButton().controlSize(.large).frame(minHeight: 44)
            Button(copied ? "已复制" : "导出诊断", action: copyDiagnostics).controlSize(.large).frame(minHeight: 44)
            #else
            Button("重试", action: retry)
            Button(copied ? "已复制" : "导出诊断", action: copyDiagnostics)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
    }

    private func copyDiagnostics() {
        #if os(iOS)
        UIPasteboard.general.string = failure.diagnostics
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failure.diagnostics, forType: .string)
        #endif
        copied = true
    }
}
