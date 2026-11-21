import CueStore
import SwiftUI

extension View {
    func refreshesQuota(open: Bool) -> some View { modifier(QuotaRefreshOnAppear(open: open)) }
}

private struct QuotaRefreshOnAppear: ViewModifier {
    let open: Bool
    @Environment(AppServices.self) private var services
    @Environment(\.pageActive) private var active
    @State private var openings = 0
    #if os(iOS)
    // 手机回到前台再看一次；Mac 的窗口由 AppKit 托管，没有 SwiftUI 场景，场景阶段一直不是 active，只看页在不在前台
    @Environment(\.scenePhase) private var phase
    private var foreground: Bool { phase == .active }
    #else
    private var foreground: Bool { true }
    #endif

    private struct Run: Equatable {
        let key: [String]
        let openings: Int
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: open) { _, open in if open { openings += 1 } }
            .task(id: active && foreground ? Run(key: services.quotaRefreshKey, openings: openings) : nil) {
                guard active && foreground else { return }
                await services.refreshQuota(.automatic)
            }
    }
}

struct QuotaRefreshNote: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        switch services.accountQuotas.phase {
        case .idle, .running(_, _, after: nil): EmptyView()
        case .running(_, _, after: let reason?): line(reason, retrying: true)
        case .failed(let reason, _, _): line(reason, retrying: false)
        }
    }

    private func line(_ reason: ShownText, retrying: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            Text("没能查到最新额度：\(reason.text)")
                .font(Typography.meta).foregroundStyle(palette.failure)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if retrying {
                Text("正在查询").font(Typography.meta).foregroundStyle(palette.ink3)
            } else {
                Button("重试") { Task { await services.refreshQuota(.manual) } }
                    .font(Typography.meta.weight(.medium))
                    .accessibilityHint("再查一次额度")
            }
        }
    }
}
