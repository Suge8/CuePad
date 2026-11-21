import CueStore
import SwiftUI

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
        let rescue = SessionRescue.of(session)
        if case .usage(let url) = rescue {
            Callout(status, text: text, docked: true) {
                Link("管理用量", destination: url).buttonStyle(ControlButtonStyle(kind: .primary))
            }
        } else if rescue == .retry {
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
        guard [.quota, .login].contains(session.failure?.known), let config,
              let models = catalog?.models, !models.isEmpty else { return nil }
        return .session(session, models: models, current: config.model?.key, in: workspace)
    }
}
