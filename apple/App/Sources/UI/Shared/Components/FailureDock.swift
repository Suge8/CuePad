import CueStore
import SwiftUI

/// 会话报不出可换的模型时只写原因。写不写只看顶栏那一个状态（`Workspace.shownInHeader`）：出错之后又说了话、点了重试，话在路上时状态就不是出错，块随之收起。
/// 贴在这里而不在对话末尾：卡在你这里的事都在回复框上方，滚到哪都看得见、按钮在拇指下。
struct FailureDock: View {
    let session: SessionState
    let delivery: DeliveryRequest?
    let catalog: AgentCatalog?
    let config: ConfigShown?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let status = workspace.shownInHeader(session, delivery: delivery).status
        let failed: Failed? = if case .failed = status { Failed(session: session, status: status) } else { nil }
        DockedCard(failed) { callout($0) }
    }

    private struct Failed: Equatable {
        let session: SessionState
        let status: SessionShown.Status
    }

    @ViewBuilder private func callout(_ failed: Failed) -> some View {
        let session = failed.session, status = failed.status
        let text = session.detail ?? String(localized: "Mac 没有说明原因")
        if let url = session.usageURL {
            Callout(status, text: text, docked: true) {
                Link("管理用量", destination: url).buttonStyle(ControlButtonStyle(kind: .primary))
            }
        } else if session.canRetry {
            Callout(status, text: text, docked: true) {
                Button { workspace.retry(session) } label: { Label("重试", icon: .retry) }
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
            }
        } else if let menu = modelMenu(session) {
            Callout(status, text: text, docked: true) {
                MenuButton(sections: menu.sections(quotas: services.accountQuotas.items, at: .now), accessibilityLabel: "换个模型") {
                    Text("换个模型").modifier(ControlSurface(kind: .secondary))
                }
            }
        } else {
            Callout(status, text: text, docked: true)
        }
    }

    private func modelMenu(_ session: SessionState) -> ModelMenu? {
        guard [.quota, .login].contains(session.failure?.known), let config, session.capabilities.contains(.model),
              let models = catalog?.models, !models.isEmpty else { return nil }
        return .session(session, models: models, current: config.model?.key, in: workspace)
    }
}
