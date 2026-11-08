import SwiftUI

/// 每次打开分享都从当前草稿取值。准备结果只属于这一份快照；关掉即取消，重开重新准备。
/// 文件未到本机立即失败，用户在编辑器中点按附件取回后可重试；不把同步等待藏在分享流程里。
struct InspirationExport: View {
    let source: String
    let originals: Bool
    let close: () -> Void
    let recover: (InspirationShare.Recovery) -> Void
    let ready: (InspirationPayload) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = Phase.loading

    private enum Phase {
        case loading
        case failed(InspirationShare.Problem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.block) {
            switch phase {
            case .loading:
                HStack(spacing: Spacing.item) { Spinner(); Text("正在准备图片…") }
                Button("取消", action: close).buttonStyle(PressStyle())
            case .failed(let problem):
                Text(problem.message).foregroundStyle(palette.failure)
                Button(problem.recovery.label) {
                    if problem.recovery == .retry { phase = .loading }
                    else { recover(problem.recovery) }
                }.buttonStyle(PressStyle())
                if problem.recovery != .close { Button("取消", action: close).buttonStyle(PressStyle()) }
            }
        }
        .padding(Spacing.panel)
        .task(id: loading) {
            guard loading else { return }
            do {
                let payload = try await InspirationShare.prepare(source, originals: originals, files: services.store.files, colorScheme: colorScheme)
                try Task.checkCancellation()
                ready(payload)
            } catch is CancellationError {
                // 浮层已关闭，旧结果不再交给分享入口。
            } catch { if !Task.isCancelled { phase = .failed(InspirationShare.Problem(error)) } }
        }
    }

    private var loading: Bool { if case .loading = phase { true } else { false } }

}
