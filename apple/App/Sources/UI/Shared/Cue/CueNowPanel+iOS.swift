#if os(iOS)
import SwiftUI

/// Cue 名牌长出的面板（`CueHeader`）：只放 Cue 自己的（Mac 上这些分在 Cue 页输入框、"运行情况"与设置里）。名牌长成的名片之下沿中轴排：
/// 它的大脑（Agent、模型与思考强度，`CueConfigControls`）与上下文那一行（`CueContextLine`），底下记忆、设置两个等宽的去处
/// （设置是 `CueSettingsScreen`：在哪台 Mac 上运行、不用先问的事、工具步骤与名字）。
/// 在做的会话不在这里：进行中的在进展页的会话段（左滑就到），点进会话只有那一条路，返回落点与行的长相都只有一种。
/// 面板只有启用前后这一个变量，两态同一个尺寸：大脑那一块按启用了的样子占位（`BrainBlock`）。
/// 面板里不放滚动区：滚动区会读到对话那块的内容边距（SwiftUI 把对话的 `contentMargins` 写到同一棵树里别的 UIScrollView 上），整块右移被裁。
struct CueNowPanel: View {
    let brain: AgentModelChoice?
    let close: () -> Void
    @Environment(Workspace.self) private var workspace

    /// 面板的字号上限：再大胶囊那一排连模型名都要截掉（iPhone 17 上辅助字号第二档就成了"Opus…"）。
    private static let largestType = DynamicTypeSize.accessibility1

    var body: some View {
        VStack(spacing: 20) {
            BrainBlock(brain: brain, choose: { go(.cueSettings) })
            HStack(spacing: 10) {
                place("记忆", icon: .memory) { workspace.cue.showsMemory = true }
                place("设置", icon: .settings) { workspace.push(.cueSettings) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .dynamicTypeSize(...Self.largestType)
    }

    /// 两个去处同宽同高：次按钮的胶囊（同页里"以后不用问"那一类），图标接字。
    private func place(_ title: String, icon: Icon, action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            Label { Text(title).lineLimit(1) } icon: { Image(icon) }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary))
    }

    private func go(_ route: Route) {
        close()
        workspace.push(route)
    }
}

/// 大脑一排与上下文一行，启用前后同一块、同样高：
/// - 启用了：胶囊（可换 Agent、模型、思考强度）与上下文用了几成；
/// - 停用了（还记着那台 Mac）：同样两行，淡下去、不可点，看得到停用前用的是什么、上下文停在几成；
/// - 还没选过在哪台运行：没有可写的大脑（只会是"默认模型"的空胶囊），这一块换成一颗"选在哪台 Mac 上运行"，点它去 Cue 的设置。
/// 高度总由启用了的两行定（看不见时也排着），换态时面板不变高。
private struct BrainBlock: View {
    let brain: AgentModelChoice?
    let choose: () -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        let chosen = cue.hostID != nil
        VStack(spacing: 10) {
            CueConfigControls(choice: brain, fail: workspace.fail, alignment: .center)
            CueContextLine(context: cue.context).frame(maxWidth: 240)
        }
        .opacity(chosen ? (cue.canHear ? 1 : Self.dimmed) : 0)
        .disabled(!cue.canHear)
        .accessibilityHidden(!chosen)
        .overlay {
            if !chosen {
                // 这时面板里唯一的下一步：用选中那一档的靛青，与下面两个去处分开
                Button("选在哪台 Mac 上运行", icon: .mac, action: choose)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(ControlButtonStyle(kind: .highlight))
            }
        }
    }

    /// 停用时那两行的浓淡：看得清是什么，又读得出点不了。
    private static let dimmed = 0.4
}
#endif
