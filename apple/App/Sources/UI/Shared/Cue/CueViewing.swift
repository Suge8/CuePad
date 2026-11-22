import SwiftUI

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
    private var onScreen: Bool { services.viewer.present }
    #endif
    @State private var appeared = false
    @State private var token = UUID()

    static let dwell: Duration = .seconds(1)

    private var watching: Bool { active && onScreen && appeared }
    private var reading: Bool { watching && !catchingUp }

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            .onDisappear {
                appeared = false
                services.viewer.showCue(false, by: token)
            }
            .onChange(of: watching, initial: true) { _, on in
                services.viewer.showCue(on, by: token)
                guard on else { return }
                follow.oweLanding()
                land()
            }
            .onChange(of: reading && thread != nil) { _, start in if start { land() } }
            .onChange(of: thread?.unread) { land() }
            .task(id: Reading(seen: Set(seen.keys), counts: reading)) { await mark() }
    }

    private struct Reading: Equatable {
        let seen: Set<UUID>
        let counts: Bool
    }

    private func land() {
        guard follow.owesLanding, reading, let thread else { return }
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

struct CueUnreadDot: View {
    let unread: Bool
    @Environment(\.palette) private var palette

    nonisolated static let gap = Spacing.glyph
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
