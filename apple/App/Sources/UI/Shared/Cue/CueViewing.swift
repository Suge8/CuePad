import SwiftUI

/// 有人在看 Cue 页的规则（算不算在看、读没读）只在这里：这一页在屏上（Mac 页栈里的当前页、人在跟前看得到主窗口 `ViewerKeeper.present`；手机上没被推进的页盖住、App 在前台）。
/// 在看的期间这一处算一个在看的（`ViewerKeeper.showCue`，Cue 的提示据此不发，手机按节奏拉），并读新消息：哪几条算新的只在 Kit 的 `CueStore.cueUnread`，读到哪只记在同步的 `CueRead`，换一台设备接着读。
struct CueViewing: ViewModifier {
    let thread: CueThread?
    let catchingUp: Bool
    @Binding var seen: [UUID: Date]
    @Binding var follow: ChatFollow
    /// 舞台开着（`CueStage`）：打开停在对话尽头的它上面，不落到第一条新消息；读到哪照样按末尾在不在屏上算（舞台在屏上时它们在上面）。
    let staged: Bool
    /// 离开够久（`CueStage.opens`）又回来看：页把舞台重开、回到最新处。离开的时刻记在本机（`AppSettings.cueLeft`），各台设备各算各的来访。
    let revisit: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    private var onScreen: Bool { phase == .active }
    #else
    private var onScreen: Bool { services.viewer.present }
    #endif
    @State private var appeared = false
    @State private var token = UUID()

    /// 末尾在屏上停这么久才算读到：打开时先停在最新处、跳到第一条新消息之前的那一下，与一路甩过去的都不算。
    static let dwell: Duration = .seconds(1)

    private var watching: Bool { active && onScreen && appeared }
    private var reading: Bool { watching && !catchingUp }

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            // 页拆掉时 onChange 不再来：在这里收回
            .onDisappear {
                // 已经不在看时拆掉（后台里关了那扇窗）：离开的时刻是当初不看的那一刻，不改写成现在
                if watching { services.settings.cueLeft = .now }
                appeared = false
                services.viewer.showCue(false, by: token)
            }
            .onChange(of: watching, initial: true) { was, on in
                services.viewer.showCue(on, by: token)
                guard on else {
                    if was { services.settings.cueLeft = .now }
                    return
                }
                follow.oweLanding()
                if !was, CueStage.opens(left: services.settings.cueLeft, at: .now) { revisit() } else { land() }
            }
            .onChange(of: reading && thread != nil) { _, start in if start { land() } }
            .onChange(of: thread?.unread) { land() }
            .task(id: Reading(seen: Set(seen.keys), counts: reading)) { await mark() }
    }

    private struct Reading: Equatable {
        let seen: Set<UUID>
        let counts: Bool
    }

    /// 不在前台的页不订阅（`pageActive`）：回到这页的那一刻手里的对话还是离开时的。先问库第一条新消息是哪条，对话里还没有它就等重新订阅送来再落。
    private func land() {
        guard follow.owesLanding, reading, !staged, let thread else { return }
        let first: UUID?
        do { first = try services.store.snapshot { try $0.cueUnread().first }.value } catch {
            workspace.fail(error)
            return
        }
        if let first, !thread.unread.contains(first) { return }
        follow.land(on: first)
    }

    private func mark() async {
        guard reading, let thread, let latest = seen.filter({ thread.unread.contains($0.key) }).values.max() else { return }
        do { try await Task.sleep(for: Self.dwell) } catch { return }
        do { try await services.store.mark(.cueRead, at: latest) } catch { workspace.fail(error) }
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

    nonisolated static let gap = Spacing.glyph
    /// 页边距至少这么宽才把点放在气泡外，不然骑在气泡左缘上（`CueRow`）。
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
