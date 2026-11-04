import SwiftUI

/// "读不出资料库"页（启动时库打不开、目录读取失败共用）：人话说明、折叠的原文、重试、导出诊断（复制到剪贴板）。
/// 没有任何写入入口：库没读出来，这时写进去的东西没有可靠的去处。
struct UnreadableLibraryView: View {
    let failure: LibraryFailure
    let retry: () -> Void
    @Environment(\.palette) private var palette

    /// 纸离窗口或屏幕左右边的距离：与各平台页面内容的边距一致。
    #if os(iOS)
    private static let margin: CGFloat = 16
    #else
    private static let margin = Spacing.page
    #endif

    var body: some View {
        EmptyState(mascot: .error, title: "读不出资料库", message: .verbatim(failure.summary)) {
            VStack(spacing: 16) {
                DisclosureGroup("详情") {
                    Text(failure.reason).font(Typography.caption.monospaced()).textSelection(.enabled)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Typography.meta).frame(maxWidth: 420)
                #if os(iOS)
                Button("重试", icon: .retry, action: retry)
                ExportDiagnosticsButton(text: failure.diagnostics).buttonStyle(ControlButtonStyle(kind: .secondary))
                #else
                HStack {
                    Button("重试", icon: .retry, action: retry)
                    ExportDiagnosticsButton(text: failure.diagnostics).buttonStyle(ControlButtonStyle(kind: .secondary))
                }
                #endif
            }
        }
        .padding(.horizontal, Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
    }
}
