#if os(iOS)
import SwiftUI

/// 首次使用才付的一次性成本在启动后空闲时先付掉（Mac 见 macOS 的 `Prewarm`）：把这些视图在窗口里隐形地挂两帧再卸下（不在前台，`pageActive` 为 false，
/// 不触发额度刷新）。现在只有 Agent 页顶上的额度总览（`QuotaStrip`）：它的成本几乎全在第一次建（视图类型、弹出框、计时文字），
/// 第一次换到 Agent 页时要多付约 4 亿条指令，之后每次只多一千多万条。没有额度记录时它什么都不画，等记录读到了再挂。
struct Prewarm: View {
    @Environment(AppServices.self) private var services
    @State private var mounted = false
    @State private var done = false

    var body: some View {
        ZStack {
            if mounted { QuotaStrip().refreshesQuota() }
        }
        .frame(width: 390)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .environment(\.pageActive, false)
        .task(id: services.accountQuotas.items.isEmpty) {
            guard !done, !services.accountQuotas.items.isEmpty else { return }
            // 首屏出来、用户还没动手：等一会儿再开始
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            mounted = true
            await NextFrame.wait()
            await NextFrame.wait()
            mounted = false
            done = true
        }
    }
}
#endif
