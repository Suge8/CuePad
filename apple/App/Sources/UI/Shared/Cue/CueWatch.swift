import CueStore
import Foundation
import Observation

/// 侧栏、菜单栏面板与 Cue 页都读这一份，不各自订阅：第一份是整个 App 手里最新的那份（`CueFeed.latest`），之后跟着 `CueFeed`。
/// 事实只有库里那一页摘要（`CueDigest`）、此刻（`SpeechClock`）与本机事实（`AppServices.cueLocal`）；这里按读的人要的粒度把它拆成一项项存下：
/// Observation 按存储属性追踪（值没变的写不通知），存整份摘要时任何一项变（在想→用工具、Cue 此刻……），书架与侧栏都要跟着重算。
/// 它那台 Mac 的在线期限由订阅到点重读（`CueStore.macOnline`），你最近一句的时限与同步通断由此刻给，这里不另计时。
@Observable
final class CueWatch {
    private(set) var name = CueDigest.empty.name
    private(set) var presence = CuePresence.derive(.empty, at: .always())
    /// 能对它说话：启用了（运行的那台 Mac 不在线也能说，开机后它会读到）。单列一项：输入框只看它，不随在想、用工具重算。
    private(set) var canHear = false
    private(set) var sending = false
    /// 刚发出、还没读到这一句：库里那条记录要下一次读库才变成 `sending`，这一小段发送钮先当帧换成发送中，不先缩没再长出来。
    /// 读到了这一句（`lastYouSaid` 变了，此时在不在路上都已算进 `sending`）或这句没写进库（`launchFailed`）就交还。
    private(set) var launching = false
    /// 你最近一句写下的时刻（`CueDigest.lastYou`）：刚发出的那句读到了没有只看它。
    private(set) var lastYouSaid: Date?
    /// 角标的数都只读它，不另存一份；内容变了才换（推出的时刻不算）。刚做完的那件到点在这里收掉（`show`），头像与数字账同一刻换。
    private(set) var now = CueNow.empty
    private(set) var wake: Wake?
    private var transition: Transition?
    private(set) var unread = 0
    private(set) var hostID: String?
    private(set) var hostName: String?
    #if os(macOS)
    private(set) var context: CueContext?
    #endif
    var draft = ComposerDraft()
    var showsMemory = false
    var showsSchedules = false
    #if os(macOS)
    var showsRun = false
    #endif

    init(_ digest: CueDigest?, at moment: Speech.Moment, local: CueNow.Local) {
        if let digest { apply(digest, at: moment, local: local) }
    }

    /// 各处的头像画的那一拍，只有这一条取法：光还在飞向头像时停在起飞那一刻的那一拍（`transition`）；你正在写时刚做完的让给"在听"（`CueBeat.composing`）。
    /// 否决过：光在飞时按 Cue 歇着推（`CueNow.settled`）——起飞前它若正在听你的话，挂闸那一下先退回歇着、到点再醒，多一次来回。
    var beat: CueBeat {
        if let transition, transition.until > .now { return transition.beat }
        return now.beat.composing(!draft.isEmpty(accepting: .files))
    }

    private struct Transition {
        let beat: CueBeat
        let until: Date
    }

    struct Send {
        let at: Date
        let beat: CueBeat
    }

    /// `seen` 是这次接力唯一的起点：光的起飞、到点点亮（接力层照它画）与小人醒（`seen` 加 `RelayFlight.wakeLanding`）都由它推出，
    /// 接力层不回报——它不在（Mac 主窗口关着、只剩输入条）时头像照样到点醒。
    struct Wake: Equatable {
        let at: Date
        let seen: Date
        let sessions: [String]
    }

    /// 你刚发出一句（`CueComposer`）：发出的光到点之前头像不露"在听"。同叫醒，由送出那一刻加 `RelayFlight.launchLanding` 推出，不等接力层回报。
    func sent(_ event: Send) {
        launching = true
        hold(event.beat, until: event.at.addingTimeInterval(RelayFlight.launchLanding))
    }

    /// 这一句没能写进库（`Workspace.speak` 放回了草稿）：没有"读到这一句"那一刻了，发送中不能留着。
    func launchFailed() { launching = false }

    func follow(_ services: AppServices) async throws {
        for try await seen in services.cueUpdates() {
            apply(seen.read.digest, at: seen.moment, local: seen.local, catchingUp: services.isCatchingUp(on: seen.read.digest.hostID))
        }
    }

    /// `catchingUp`：同步追赶中带回来的叫醒不播、不等（那是不在眼前时发生过的事）。
    private func apply(_ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local, catchingUp: Bool = false) {
        name = digest.name
        let presence = CuePresence.derive(digest, at: moment)
        self.presence = presence
        canHear = presence != .disabled
        sending = if case .sending = presence { true } else { false }
        if lastYouSaid != digest.lastYou?.said { launching = false }
        lastYouSaid = digest.lastYou?.said
        // 推出的时刻每次都不同：内容一样就不写，免得读它的每一行跟着重算
        noteWake(digest.woke, catchingUp: catchingUp)
        let next = AppServices.cueNow(digest, at: moment, local: local).aged(to: .now)
        if !isPinned, !next.same(as: now) { show(next) }
        unread = digest.unread
        hostID = digest.hostID
        hostName = digest.hostName
        #if os(macOS)
        context = digest.state?.context
        #endif
    }

    /// 调试画面手动换的 Cue 此刻（`-CuePadCueCycle` 轮流走各态，`DebugScene.cueNowTourIfAsked`）：换过就不再随库变。
    @ObservationIgnored private var isPinned = false

    func pin(_ next: CueNow) {
        isPinned = true
        show(next.aged(to: .now))
    }

    @ObservationIgnored private var aging: Task<Void, Never>?
    /// 看过的最近一次叫醒（记录的时刻）；还没读到第一份摘要时为 nil，第一份里已有的算看过。看过到哪只有这一个起点。
    @ObservationIgnored private var wokeSeen: Date?
    @ObservationIgnored private var releasing: Task<Void, Never>?

    /// 摘要里比看过的更新的会话叫醒：记下本机看到它的此刻，头像等到光落下。与"在想"同一次 `apply` 里生效，谁先谁后不来回。
    private func noteWake(_ woke: CueDigest.Woke?, catchingUp: Bool) {
        guard let seen = wokeSeen else { return wokeSeen = woke?.at ?? .distantPast }
        guard let woke, woke.at > seen else { return }
        wokeSeen = woke.at
        guard let sessions = woke.sessions, !catchingUp else { return }
        let next = Wake(at: woke.at, seen: .now, sessions: sessions)
        wake = next
        hold(beat, until: next.seen.addingTimeInterval(RelayFlight.wakeLanding))
    }

    /// 期限内连续叫醒等最后一道光；过期后新事件捕获当前显示值，不延续旧快照。任务只通知重画，读值以期限为准。
    private func hold(_ snapshot: CueBeat, until end: Date) {
        let active = transition.flatMap { $0.until > .now ? $0 : nil }
        let end = max(active?.until ?? end, end)
        transition = Transition(beat: active?.beat ?? snapshot, until: end)
        releasing?.cancel()
        releasing = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow), tolerance: .zero)) != nil else { return }
            self?.transition = nil
        }
    }

    /// 换上这一份，睡到刚做完的那件该收的那一刻（`CueNow.nextChange`；等到那一刻是业务语义，不周期刷新）再收掉。
    private func show(_ next: CueNow) {
        now = next
        aging?.cancel()
        guard let at = next.nextChange(after: .now) else { return }
        aging = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow))) != nil, let self else { return }
            show(now.aged(to: at))
        }
    }
}
