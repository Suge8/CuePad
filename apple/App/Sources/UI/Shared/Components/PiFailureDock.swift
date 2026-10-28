import CueStore
import SwiftUI

/// 会话出错时贴在回复框上方的那块（同问题卡的位置，`SessionDock`）：写原因原文，下面一颗按钮——重跑这一轮有用且做得到时"重试"
/// （`PiSessionState.canRetry`，`Workspace.retry`）；额度用完、登录失效时"换个模型"，点开就是回复框里那份模型菜单（`PiModelMenu.session`），
/// 会话报不出可换的模型时只写原因。写不写只看顶栏那一个状态（`Workspace.shownInHeader`）：出错之后又说了话、点了重试，话在路上时状态就不是出错，块随之收起。
/// 贴在这里而不在对话末尾：卡在你这里的事都在回复框上方，滚到哪都看得见、按钮在拇指下。
struct PiFailureDock: View {
    let session: PiSessionState
    /// 发给它的最近一条话（`SessionDigest.delivery`）
    let delivery: DeliveryRequest?
    let catalog: AgentCatalog?
    let config: PiConfigShown?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let status = workspace.shownInHeader(session, delivery: delivery).status
        if case .failed = status {
            let text = session.detail ?? String(localized: "Mac 没有说明原因")
            if session.canRetry {
                Callout(status, text: text, docked: true) {
                    Button { workspace.retry(session) } label: { Label("重试", icon: .retry) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary))
                }
            } else if let menu = modelMenu {
                Callout(status, text: text, docked: true) {
                    MenuButton(sections: menu.sections(quotas: services.accountQuotas.items, at: .now), accessibilityLabel: "换个模型") {
                        Text("换个模型").modifier(ControlSurface(kind: .secondary))
                    }
                }
            } else {
                Callout(status, text: text, docked: true)
            }
        }
    }

    /// 额度与登录卡住的才换模型；同回复框有没有模型胶囊（`PiReplyBar.hasTools`）。
    private var modelMenu: PiModelMenu? {
        guard [.quota, .login].contains(session.failure?.known), let config, session.capabilities.contains(.model),
              let models = catalog?.models, !models.isEmpty else { return nil }
        return .session(session, models: models, current: config.model?.key, in: workspace)
    }
}
