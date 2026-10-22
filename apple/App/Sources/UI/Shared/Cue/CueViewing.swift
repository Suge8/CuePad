import SwiftUI

/// 有人在看 Cue 页：这一页在屏上（Mac 页栈里的当前页、人看得到主窗口——露在屏上、有没有焦点都算、人没走开，`AppServices.seesMainWindow`；
/// 手机上没被推进的页盖住、App 在前台）。在看的期间——
/// - 算一个在看的（`AppServices.cueViewers`）：这台设备开着 Cue 页（`ViewerKeeper.showCue`，Cue 的提示据此不发，见 `AlertCenter`），手机按节奏拉；
/// - 读新消息（哪几条算新的只在 Kit 的 `CueStore.cueUnread`，读到哪只记在同步的 `CueRead`，换一台设备接着读）。
/// 新消息是气泡旁的一颗小点（`CueUnreadDot`），不插进对话：来去都不重排。开始看（进来、App 回到前台、窗口重新露出来）
/// 又没在和 iCloud 对时，有新消息就从第一条读起（`ChatFollow.Landing.read`：停在顶上，下面不到一屏时滚动区停在最新处）。
/// 读没读按条算：一条新消息的末尾在滚动区里停够 `dwell` 就算读到了它（`CueRow` 报看见，这里取最晚的一条合并成一次写），
/// 打开时先停在最新处那一下、甩过去的不算；没在看、正在和 iCloud 对时不算。
struct CueViewing: ViewModifier {
    let thread: CueThread?
    let catchingUp: Bool
    /// 末尾此刻在滚动区里的新消息与它写下的时刻（`CueRow` 写）。
    @Binding var seen: [UUID: Date]
    @Binding var follow: ChatFollow
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    private var onScreen: Bool { phase == .active }
    #else
    /// 人看得到主窗口（`AppServices.seesMainWindow`：窗口露在屏上、人在跟前）。脚本起的验收实例窗口排在最后，当它露着
    private var onScreen: Bool { services.seesMainWindow || DebugHooks.scripted }
    #endif
    /// 页面在屏上（推进了别的页盖住它时不在）。
    @State private var appeared = false
    /// 已算进 `cueViewers`。
    @State private var counted = false

    /// 末尾在屏上停这么久才算读到：打开时先停在最新处、跳到第一条新消息之前的那一下，与一路甩过去的都不算。
    static let dwell: Duration = .seconds(1)

    private var watching: Bool { active && onScreen && appeared }
    /// 读到的算数：在看、又没在和 iCloud 对（对的时候对话还不是最新的）。
    private var reading: Bool { watching && !catchingUp }

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            // 页拆掉时 onChange 不再来：在这里收回
            .onDisappear {
                appeared = false
                count(false)
            }
            .onChange(of: watching, initial: true) { _, on in count(on) }
            .onChange(of: reading && thread != nil, initial: true) { _, start in if start { land() } }
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
        guard let thread, let first = thread.rows.first(where: { thread.unread.contains($0.id) }) else { return }
        follow.seek(first.id, landing: .read)
    }

    private func mark() async {
        guard reading, let thread, let latest = seen.filter({ thread.unread.contains($0.key) }).values.max() else { return }
        do { try await Task.sleep(for: Self.dwell) } catch { return }
        do { try await services.store.markCueRead(through: latest) } catch { workspace.fail(error) }
    }
}

/// 一条新消息的末尾在不在可见区里：在滚动区里、又不在浮着的输入框与"等你"卡底下（`chatBottomInset`）才算看到了这一条（长的回答要读到底）。
/// 被盖着的那截仍在滚动区里，可见性回调（`onScrollVisibilityChange`）分不出，所以按滚动区此刻的边界自己比；只报变化，
/// 浮着的那块的高在这里读，升起时每帧变也只重算新消息的这一格。
/// 滚动区这个坐标空间不含上下的内容边距（`ChatLayout.edge`），浮着那块的高却是从滚动区真正的下沿量起：比之前补回这一截。
/// 末尾按最后一行字算，不按气泡的下沿（量的这一线抬起气泡的下内边距）：最后一颗气泡的底常常刚好压在"等你"卡的上沿下一两点，
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

/// 还没读的 Cue 的话：气泡左边外侧一颗石绿小点（新消息的颜色，同入口的点与侧栏的数，`CueDot`），对着第一行字；读到了淡出。
/// 叠在格子上、不占地方：来去不重排。高按第一行字量（一个看不见的字），跟着动态字体走。
struct CueUnreadDot: View {
    let unread: Bool
    @Environment(\.palette) private var palette

    nonisolated static let size: CGFloat = 7
    /// 点与气泡左缘之间。
    nonisolated static let gap: CGFloat = 6
    /// 页边距至少这么宽才把点放在气泡外（点、缝，离屏缘再留一条缝），不然骑在气泡左缘上（`CueRow`）。
    nonisolated static let room: CGFloat = size + gap + 8
    static let fade = Animation.easeOut(duration: 0.5)

    var body: some View {
        Text(verbatim: " ").font(Typography.reading).hidden()
            .frame(width: Self.size)
            .overlay {
                if unread { Circle().fill(palette.replied).frame(width: Self.size, height: Self.size).transition(.opacity) }
            }
            .animation(Self.fade, value: unread)
            .padding(.top, CueBubble.padding.top)
            .accessibilityLabel("新消息")
            .accessibilityHidden(!unread)
    }
}
