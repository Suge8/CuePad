#if os(iOS)
import CueSync
import SwiftUI

/// 标签根页（iPhone 的 Cue、灵感、搜索）顶上一排：左边设置（`SettingsButton`，只在标签栏布局有，iPad 的设置在侧栏），
/// 中间是这一页的主体（搜索框；Cue 页头浮在这一排上，见 `CueHeader`；没有就空着，不写标签名），右边是本页唯一的新建（没有就空着）。
/// 不放搜索框以外的状态与"⋯"：顶栏的规则见 docs/ui.md。浮在内容上（滚动到它下面的内容渐隐），不放进导航栏：导航栏中间那一格按内容宽度居中，占不满。
struct RootBar<Center: View, Trailing: View>: View {
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing
    @Environment(Navigation.self) private var navigation

    var body: some View {
        HStack(spacing: 8) {
            if navigation.layout == .tabs { SettingsButton() }
            if Center.self == EmptyView.self { Spacer(minLength: 0) } else { center.frame(maxWidth: .infinity) }
            trailing
        }
        .buttonStyle(ControlButtonStyle(kind: .circular)).labelStyle(.iconOnly)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
        // iPad 窗口的关闭、缩小、排列钮在左上角：这一排是自绘的、不在导航栏里，系统不替它让位，按窗口给的角落整排让出来
        // （连同页边距一起让，窗口钮就当是屏幕边。顶上的提示横幅按同一处让，见 `NoticeBanner`）
        .containerCornerOffset(.horizontal, sizeToFit: true)
    }
}

extension RootBar where Trailing == EmptyView {
    init(@ViewBuilder center: () -> Center) { self.init(center: center) { EmptyView() } }
}

/// 设置的唯一入口（iPhone 每个标签根页的左上角，同 Mac 侧栏底栏那颗一直在的齿轮）：同步到不了 Mac 时右上带一个点，
/// 颜色是同步状态的（提示赭黄、真出错胭脂），点进设置看 iCloud 那一节；平时不带。
struct SettingsButton: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let status = services.syncStatus
        Button { navigation.push(.settings) } label: {
            Label("设置", systemImage: "gearshape")
                .overlay(alignment: .topTrailing) {
                    if !status.reachesMac {
                        Circle().fill(palette.color(SyncSummary(status).tone)).frame(width: 7, height: 7).offset(x: 3, y: -1)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityValue(status.reachesMac ? "" : SyncSummary(status).title)
    }
}

/// 搜索框：玻璃胶囊（搜索页顶上）。在输入或有字时右端一个叉：清空并收起键盘。
struct SearchCapsule: View {
    static let height: CGFloat = ControlMetrics.height
    let prompt: String
    @Binding var query: String
    let focus: FocusState<Bool>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $query).submitLabel(.search).focused(focus).accessibilityLabel("搜索")
            if !query.isEmpty || focus.wrappedValue {
                Button("清除", systemImage: "xmark.circle.fill") {
                    query = ""
                    focus.wrappedValue = false
                }
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .quiet, compact: true))
            }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: Self.height)
        .glass(in: .capsule)
    }
}
#endif
