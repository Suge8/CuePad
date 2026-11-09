import SwiftUI

/// 有人在看 Cue 页的规则（算不算在看、读没读）只在这里：这一页在屏上（Mac 页栈里的当前页、人看得到主窗口 `AppServices.seesMainWindow`；手机上没被推进的页盖住、App 在前台）。
/// 在看的期间算一个在看的（`AppServices.cueViewers`，Cue 的提示据此不发，手机按节奏拉），并读新消息：哪几条算新的只在 Kit 的 `CueStore.cueUnread`，读到哪只记在同步的 `CueRead`，换一台设备接着读。
struct CueViewing: ViewModifier {
    let thread: CueThread?
    let catchingUp: Bool
    @Binding var seen: [UUID: Date]
    @Binding var follow: ChatFollow
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    private var onScreen: Bool { phase == .active }
    #else
    /// 脚本起的验收实例窗口排在最后，当它露着。
    private var onScreen: Bool { services.seesMainWindow || DebugHooks.scripted }
    #endif
    @State private var appeared = false
    @State private var counted = false

    /// 末尾在屏上停这么久才算读到：打开时先停在最新处、跳到第一条新消息之前的那一下，与一路甩过去的都不算。
    static let dwell: Duration = .seconds(1)

    private var watching: Bool { active && onScreen && appeared }
    private var reading: Bool { watching && !catchingUp }

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            // 页拆掉时 onChange 不再来：在这里收回
            .onDisappear {
                appeared = false
                count(false)
            }
            .onChange(of: watching, initial: true) { _, on in
                count(on)
                guard on else { return }
                follow.oweLanding()
                land()
            }
            .onChange(of: reading && thread != nil) { _, start in if start { land() } }
            .task(id: Reading(seen: Set(seen.keys), counts: reading)) { await mark() }
    }

    private struct Reading: Equatable {
        let seen: Set<UUID>
        let counts: Bool
    }

    private func count(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        services.cueViewers += on ? 1 : -1
        services.viewer?.showCue(services.cueViewers > 0)
    }

    private func land() {
        guard reading, let thread else { return }
        follow.land(on: thread.rows.first { thread.unread.contains($0.id) }?.id)
    }

    private func mark() async {
        guard reading, let thread, let latest = seen.filter({ thread.unread.contains($0.key) }).values.max() else { return }
        do { try await Task.sleep(for: Self.dwell) } catch { return }
        do { try await services.store.markCueRead(through: latest) } catch { workspace.fail(error) }
    }
}

/// 被盖着的那截仍在滚动区里，可见性回调（`onScrollVisibilityChange`）分不出，所以按滚动区此刻的边界自己比；只报变化，
/// 浮着的那块的高在这里读，升起时每帧变也只重算新消息的这一格。
/// 滚动区这个坐标空间不含上下的边（`ChatLayout.edge`），浮着那块的高却是从滚动区真正的下沿量起：比之前补回这一截。
/// 末尾按最后一行字算，不按气泡的下沿（量的这一线抬起气泡的下内边距）：最后一颗气泡的底常常刚好压在拍板卡的上沿下一两点，
/// 字全露着也读不到它。拆掉时（读过了不再是新消息、离屏远的段换成空白）报一次不在：甩过去的不留下"看见了"。
struct CueEndProbe: View {
    let seen: (Bool) -> Void
    @Environment(\.chatBottomInset) private var covered

    var body: some View {
        Color.clear.frame(height: 1)
            .onGeometryChange(for: Bool.self) { [covered] proxy in
                guard let visible = proxy.bounds(of: .scrollView) else { return false }
                return visible.minY <= ChatLayout.edge && 1 <= visible.maxY + ChatLayout.edge - covered
            } action: { seen($0) }
            .onDisappear { seen(false) }
            .padding(.bottom, CueBubble.padding.bottom)
    }
}

/// 叠在格子上、不占地方：来去不重排。高按第一行字量（一个看不见的字），跟着动态字体走。
struct CueUnreadDot: View {
    let unread: Bool
    @Environment(\.palette) private var palette

    nonisolated static let gap: CGFloat = 6
    static let room = StatusDot.size + gap + Spacing.item

    var body: some View {
        Text(verbatim: " ").font(Typography.reading).hidden()
            .frame(width: StatusDot.size)
            .overlay {
                if unread { StatusDot(color: palette.replied).transition(.opacity) }
            }
            .animation(Motion.fade, value: unread)
            .padding(.top, CueBubble.padding.top)
            .accessibilityLabel("新消息")
            .readerHidden(!unread)
    }
}
