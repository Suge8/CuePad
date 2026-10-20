import CueStore
import SwiftUI

/// 有人在看 Cue 页：这一页在前台（Mac 页栈里的当前页；手机上没被推进的页盖住）、App 也在前台（Mac 是窗口活跃）。在看的期间——
/// - 算一个在看的（`AppServices.cueViewers`）：Cue 的通知不发（Mac 见 `AlertPresentation`，iOS 前台的系统横幅），手机按节奏拉；
/// - 读新消息（哪几条算新的只在 Kit 的 `CueStore.cueUnread`，读到哪只记在同步的 `CueRead`，换一台设备接着读）。
/// 开始看这一页时（进来、App 回到前台、看着时和 iCloud 对完一次而还没有分隔线）记下分隔线的位置（`CueThread.divider`）：
/// 第一条新消息上面一条石绿的"以下 N 条新消息"（`CueNewMessages`），这次看着的期间一直在，下次开始看时按那时的位置画（读完了就没有）；
/// 有新消息就从它读起（`ChatFollow.Landing.read`：停在顶上，下面不到一屏时滚动区停在最新处）。
/// 读没读按条算：一条新消息的末尾在滚动区里停够 `dwell` 就算读到了它（`CueRow` 报看见，这里取最晚的一条合并成一次写），
/// 打开时先停在最新处那一下、甩过去的不算；没在看、正在和 iCloud 对时不算。
nonisolated struct CueDivider: Equatable, Sendable {
    let id: UUID
    let count: Int
}

struct CueViewing: ViewModifier {
    let thread: CueThread?
    let catchingUp: Bool
    @Binding var divider: CueDivider?
    /// 末尾此刻在滚动区里的新消息与它写下的时刻（`CueRow` 写）。
    @Binding var seen: [UUID: Date]
    @Binding var follow: ChatFollow
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    private var foreground: Bool { phase == .active }
    #else
    // Mac 的窗口由 AppKit 托管，场景阶段一直不是 active：看窗口是不是活跃的那一个。脚本起的验收实例在后台跑，当它在前台
    @Environment(\.appearsActive) private var appearsActive
    private var foreground: Bool { appearsActive || DebugHooks.scripted }
    #endif
    /// 页面在屏上（推进了别的页盖住它时不在）。
    @State private var appeared = false
    /// 已算进 `cueViewers`。
    @State private var counted = false

    /// 末尾在屏上停这么久才算读到：打开时先停在最新处、跳到分隔线之前的那一下，与一路甩过去的都不算。
    static let dwell: Duration = .seconds(1)

    private var watching: Bool { active && foreground && appeared }

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            // 页拆掉时 onChange 不再来：在这里收回
            .onDisappear {
                appeared = false
                count(false)
            }
            .onChange(of: watching, initial: true) { _, on in count(on) }
            .onChange(of: watching && thread != nil, initial: true) { _, on in
                guard on else { return }
                divider = nil
                land()
            }
            .onChange(of: catchingUp) { _, syncing in
                if !syncing, watching, divider == nil { land() }
            }
            .task(id: Reading(seen: Set(seen.keys), counts: watching && !catchingUp)) { await mark() }
    }

    private struct Reading: Equatable {
        let seen: Set<UUID>
        let counts: Bool
    }

    private func count(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        services.cueViewers += on ? 1 : -1
    }

    private func land() {
        guard let next = thread?.divider else { return }
        divider = next
        follow.seek(next.id, landing: .read)
    }

    private func mark() async {
        guard watching, !catchingUp, let thread, let latest = seen.filter({ thread.unread.contains($0.key) }).values.max() else { return }
        do { try await Task.sleep(for: Self.dwell) } catch { return }
        do { try await services.store.markCueRead(through: latest) } catch { workspace.fail(error) }
    }
}

/// 一条新消息的末尾在不在可见区里：在滚动区里、又不在浮着的输入框与"等你"卡底下（`chatBottomInset`）才算看到了这一条（长的回答要读到底）。
/// 被盖着的那截仍在滚动区里，可见性回调（`onScrollVisibilityChange`）分不出，所以按滚动区此刻的边界自己比；只报变化，
/// 浮着的那块的高在这里读，升起时每帧变也只重算新消息的这一格。
/// 滚动区这个坐标空间不含上下的内容边距（`ChatLayout.edge`），浮着那块的高却是从滚动区真正的下沿量起：比之前补回这一截。
/// 末尾按最后一行字算，不按气泡的下沿（量的这一线抬起气泡的下内边距）：打开时停在分隔线上，下面那条的气泡底常常刚好压在"等你"卡的上沿下一两点，
/// 字全露着也读不到它。
struct CueEndProbe: View {
    let seen: (Bool) -> Void
    @Environment(\.chatBottomInset) private var covered

    var body: some View {
        Color.clear.frame(height: 1)
            .onGeometryChange(for: Bool.self) { [covered] proxy in
                guard let visible = proxy.bounds(of: .scrollView) else { return false }
                return visible.minY <= ChatLayout.edge && 1 <= visible.maxY + ChatLayout.edge - covered
            } action: { seen($0) }
            .padding(.bottom, CueBubble.padding.bottom)
    }
}

/// 第一条新消息上面那条线：与换新的分隔同一种居中的线（`ChatMarker`），字与线是石绿（有新回复的颜色）。
struct CueNewMessages: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        ChatMarker(ruled: true, tint: palette.replied) { Text("以下 \(count) 条新消息") }
    }
}
