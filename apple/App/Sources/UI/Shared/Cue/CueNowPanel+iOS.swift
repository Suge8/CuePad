#if os(iOS)
import SwiftUI

/// Cue 名牌长出的面板（`CueHeader`）：只放 Cue 自己的（Mac 上这些分在 Cue 页输入框、"运行情况"与设置里）。名牌长成的名片之下沿中轴排：
/// 它的大脑（Agent、模型与思考强度，`CueConfigControls`）与上下文那一行（`CueContextLine`），底下记忆、设置两个等宽的去处
/// （设置推入设置页，Cue 的名字与在哪台 Mac 上运行在它最上面一组）。
/// 在做的会话不在这里：进行中的在进展页的会话段（左滑就到），点进会话只有那一条路，返回落点与行的长相都只有一种。
/// 面板只有启用前后这一个变量，两态同一个尺寸：大脑那一块按启用了的样子占位（`BrainBlock`）。
/// 面板里不放滚动区（docs/ui.md 布局约束）。
struct CueNowPanel: View {
    let brain: AgentModelChoice?
    let close: () -> Void
    @Environment(Workspace.self) private var workspace

    /// 面板的字号上限：再大胶囊那一排连模型名都要截掉（iPhone 17 上辅助字号第二档就成了"Opus…"）。
    private static let largestType = DynamicTypeSize.accessibility1

    var body: some View {
        VStack(spacing: 20) {
            BrainBlock(brain: brain)
            HStack(spacing: 10) {
                place("记忆", icon: .memory) { workspace.cue.showsMemory = true }
                place("设置", icon: .settings) { workspace.push(.settings) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .dynamicTypeSize(...Self.largestType)
    }

    /// 两个去处同宽同高：次按钮的胶囊，图标接字。
    private func place(_ title: LocalizedStringResource, icon: Icon, action: @escaping () -> Void) -> some View {
        Button { go(action) } label: {
            Label { Text(title).lineLimit(1) } icon: { Image(icon) }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary))
    }

    /// 点面板里的一项：先收起，再去那里。
    private func go(_ action: () -> Void) {
        close()
        action()
    }
}

/// 大脑一排与上下文一行，启用前后同一块、同样高：
/// - 启用了：胶囊（可换 Agent、模型、思考强度）与上下文用了几成；
/// - 停用了（还记着那台 Mac）：同样两行，淡下去、不可点，看得到停用前用的是什么、上下文停在几成；
/// - 还没选过在哪台运行：没有可写的大脑（只会是"默认模型"的空胶囊），这一块换成一颗"选在哪台 Mac 上运行"，点开就地弹出 Mac 列表直接选（`CueHostPick`）。
/// 高度总由启用了的两行定（看不见时也排着），换态时面板不变高。
private struct BrainBlock: View {
    let brain: AgentModelChoice?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        let chosen = cue.hostID != nil
        VStack(spacing: 10) {
            CueConfigControls(choice: brain, alignment: .center)
            CueContextLine(context: cue.context).frame(maxWidth: 240)
        }
        .opacity(chosen ? (cue.canHear ? 1 : Self.dimmed) : 0)
        .disabled(!cue.canHear)
        .accessibilityHidden(!chosen)
        .overlay {
            if !chosen { CueHostPick() }
        }
    }

    /// 停用时那两行的浓淡：看得清是什么，又读得出点不了。
    private static let dimmed = 0.4
}
/// 还没选在哪台运行时面板里唯一的下一步：一颗"选在哪台 Mac 上运行"（选中那一档的靛青，与下面两个去处分开），点开是各入口同一份的 Mac 列表
/// （`CueHostMenu`），选一台就在那台启用、面板留着，启用了这一块换成大脑。启用中转圈，没写成的原因写在下面；
/// 还没和 iCloud 对过时只写在等什么，还没有哪台 Mac 写下过自己时写先去 Mac 上打开。
private struct CueHostPick: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    private static var title: String { String(localized: "选在哪台 Mac 上运行") }

    var body: some View {
        let settings = model.settings ?? .empty
        let hosts = settings.hosts(here: nil)
        VStack(spacing: 6) {
            if let waiting = settings.gate(services).waitingReason {
                HStack(spacing: 8) {
                    Spinner(.small)
                    Text(waiting)
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3)
            } else if hosts.isEmpty {
                Text(CueSettings.noHost).font(Typography.secondary).foregroundStyle(palette.ink3)
            } else {
                HStack(spacing: 8) {
                    CueHostMenu(hosts: hosts, use: .enable { model.choose($0, services) }, accessibilityLabel: Self.title) {
                        Label(Self.title, icon: .mac)
                            .labelStyle(.titleAndIcon)
                            .modifier(ControlSurface(kind: .highlight))
                    }
                    if model.enabling != nil { Spinner(.small) }
                }
                .disabled(model.enabling != nil)
            }
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure).multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .cueSettings(model)
    }
}
#endif
