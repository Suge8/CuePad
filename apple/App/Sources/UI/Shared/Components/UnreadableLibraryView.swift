import SwiftUI

/// "读不出资料库"页（启动时库打不开、目录读取失败共用）：人话说明、折叠的原文、重试、导出诊断（复制到剪贴板）。
/// 没有任何写入入口：库没读出来，这时写进去的东西没有可靠的去处。
struct UnreadableLibraryView: View {
    let failure: LibraryFailure
    let retry: () -> Void
    @Environment(\.palette) private var palette
    @State private var details = false

    /// 纸离窗口或屏幕左右边的距离：与各平台页面内容的边距一致。
    private static let margin = Spacing.page

    /// 纸最宽多少：整窗只有这一张（Mac 主窗口、iPad）时不铺满，同启动时打不开库那一扇窗的宽。
    private static let widest: CGFloat = 520

    var body: some View {
        EmptyState(mascot: .error, title: "读不出资料库", message: .verbatim(failure.summary)) {
            VStack(spacing: Spacing.block) {
                Button { details.toggle() } label: {
                    HStack(spacing: Spacing.glyph) {
                        Text("详情")
                        Chevron(details ? .expand : .forward)
                    }
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                }
                .buttonStyle(PressStyle(.inline))
                .accessibilityValue(details ? "已展开" : "已折叠")
                if details {
                    Text(failure.reason).font(Typography.caption.monospaced()).textSelection(.enabled)
                        .multilineTextAlignment(.leading).frame(maxWidth: 420, alignment: .leading)
                }
                #if os(iOS)
                Grid(verticalSpacing: 16) {
                    GridRow { Button("重试", icon: .retry, action: retry).buttonStyle(EqualButtonStyle(kind: .primary)) }
                    GridRow { ExportDiagnosticsButton(text: failure.diagnostics).buttonStyle(EqualButtonStyle(kind: .secondary)) }
                }
                .fixedSize(horizontal: true, vertical: false)
                #else
                HStack {
                    Button("重试", icon: .retry, action: retry)
                    ExportDiagnosticsButton(text: failure.diagnostics).buttonStyle(ControlButtonStyle(kind: .secondary))
                }
                #endif
            }
        }
        .frame(maxWidth: Self.widest)
        .padding(.horizontal, Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
    }
}

#if os(iOS)
private struct EqualButtonStyle: ButtonStyle {
    let kind: ControlButtonStyle.Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity)
            .modifier(ControlSurface(kind: kind))
            .modifier(PressFeedback(pressed: configuration.isPressed, kind: .control))
    }
}
#endif
