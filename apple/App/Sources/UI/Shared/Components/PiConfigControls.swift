import CueStore
import SwiftUI


/// Mac 的 ⌘⇧M、⌘⇧E（`ReplyShortcut`）请弹出的那个菜单。
enum PiConfigPick { case model, thinking }


/// 回复框下方的模型与思考强度（iOS 会话页、Mac 会话页共用）：左边模型胶囊（提供方图标 + 模型短名；有订阅额度的提供方，图标外一圈细环是卡着的那个窗口用了多少。
/// 点开按提供方分组的菜单，有额度的分组标题写"Claude · 5 小时 14% · 本周 8%"，当前打勾，每个写着它支持的强度、带提供方图标），右边思考强度胶囊（"思考"的标 + 一组竖格：格数是当前模型支持的档位，一格比一格高，
/// 当前档以下填满，关着时格全空、一道斜线；点在哪格或横着拖就调到哪档，每过一档轻触一下；按下就在上方浮出档位名，
/// 松手后停一会儿再淡出，点"思考"的标只看现在是哪档；最高档填色有一道流光）。
/// 显示值由会话记录与配置请求推出（`SessionDigest.config`）：换了之后立即显示新值、填色轻轻呼吸直到送达，没换成回到原值
/// （原因由调用方写在输入框头部）。只给在线会话（已结束的不为换模型去唤醒 Pi），由调用方决定放不放。减弱动态效果时没有流光与呼吸。
struct PiConfigControls: View {
    let session: PiSessionState
    /// 可以换成的模型（`AgentCatalog.models`）。
    let models: [PiModelOption]
    let shown: PiConfigShown
    /// 键盘请弹出的菜单（Mac）：弹出后清掉。
    var opening: Binding<PiConfigPick?> = .constant(nil)
    @Environment(Workspace.self) var workspace
    @Environment(AppServices.self) var services
    /// 这一排拿到的宽度：模型胶囊最宽是它的一半（`PiModelLabel.capsuleWidth`）。
    @State private var available: CGFloat = 0
    /// 键盘弹出的菜单贴着哪枚胶囊（Mac）。
    @State var anchors = [PiConfigPick.model: PopUpAnchor(), .thinking: PopUpAnchor()]

    var body: some View {
        // 放得下时思考强度写"思考 中"，窄处（手机）只写档名"中"：三枚胶囊都不截断
        ViewThatFits(in: .horizontal) {
            row(wordy: true)
            row(wordy: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .onChange(of: opening.wrappedValue) { _, pick in
            guard let pick else { return }
            opening.wrappedValue = nil
            open(pick)
        }
        #if os(macOS)
        .task {
            guard DebugHooks.preset.modelMenu, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            open(.model)
        }
        #endif
    }

    private func row(wordy: Bool) -> some View {
        HStack(spacing: 6) {
            modelCapsule
            if let levels = shown.model?.thinkingLevels, !levels.isEmpty {
                PiThinkingDial(meter: PiThinkingMeter(levels: levels, current: shown.thinking), pending: shown.pending, wordy: wordy) {
                    configure(PiConfig(thinking: $0))
                }
                .popUpAnchor(anchors[.thinking])
            }
            if let meter = shown.context.flatMap(PiContextMeter.init) { PiContextGauge(session: session, meter: meter) }
        }
        .fixedSize()
    }

    private var modelCapsule: some View {
        #if os(macOS)
        PiModelCapsule(models: models, current: shown.model, pending: shown.pending,
                       maxWidth: PiModelLabel.capsuleWidth(available: available), quotas: services.accountQuotas.items,
                       choose: { configure(PiConfig(model: $0)) }, pick: { open(.model) })
            .popUpAnchor(anchors[.model])
        #else
        PiModelCapsule(models: models, current: shown.model, pending: shown.pending,
                       maxWidth: PiModelLabel.capsuleWidth(available: available), quotas: services.accountQuotas.items) {
            configure(PiConfig(model: $0))
        }
        #endif
    }

    func configure(_ config: PiConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}
