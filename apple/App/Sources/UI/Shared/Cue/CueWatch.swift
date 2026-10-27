import CueStore
import Foundation
import Observation

/// 一个窗口里 Cue 的现状和 Cue 页的输入草稿：侧栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
/// 事实只有库里那一页摘要（`CueDigest`）、此刻（`SpeechClock`）与本机事实（`AppServices.cueLocal`）；这里按读的人要的粒度把它拆成一项项存下——
/// Observation 按存储属性追踪（值没变的写不通知），存整份摘要时任何一项变（在想→用工具、Cue 此刻……），书架与侧栏都要跟着重算。
/// 在不在、话在不在路上随库与此刻重算：它那台 Mac 的在线期限由订阅到点重读（`CueStore.macOnline`），你最近一句的时限与同步通断由
/// 此刻给，这里不另计时。
/// 第一份是整个 App 手里最新的那份（`CueFeed.latest`），之后跟着整个 App 那一份（`CueFeed`），不自己订阅：没有"还没读到"时的默认现状。
@Observable
final class CueWatch {
    private(set) var name = CueDigest.empty.name
    private(set) var presence = CuePresence.derive(.empty, at: .always())
    /// 能对它说话：启用了（运行的那台 Mac 不在线也能说，开机后它会读到）。单列一项：输入框只看它，不随在想、用工具重算。
    private(set) var canHear = false
    /// 你最近一句还在路上（`CuePresence.sending`）：输入框的发送钮只看它，不随在想、用工具重算。
    private(set) var sending = false
    /// 你最近一句写下的时刻（`CueDigest.lastYou`）：刚发出的那句读到了没有只看它。
    private(set) var lastYouSaid: Date?
    /// Cue 此刻（`CueNow`）：头像那一拍、数字账、拍板几件（底部那一排与侧栏进展那一行的"等你 M"、入口的点）、推进中几件、
    /// 角标的数都只读它，不另存一份；内容变了才换（推出的时刻不算）。刚做完的那件到点在这里收掉（`show`），头像与数字账同一刻换。
    private(set) var now = CueNow.empty
    /// 这一次会话叫醒的接力（`Wake`）：接力层（`CueRelayStage`）照它画光，头像照它醒。
    private(set) var wake: Wake?
    /// 有光正飞向头像（叫醒、发出）时头像停在光起飞那一刻的那一拍（`beat`），到点才换；没有光在飞为 nil。
    private var transition: Transition?
    /// 新消息有几条（`CueDigest.unread`）。
    private(set) var unread = 0
    /// 它最近一句（`CueDigest.lastSaid`）：只有 Mac 侧栏名片的气泡读。
    private(set) var lastSaid: String?
    /// 它运行的那台 Mac 与它的名字（`CueDigest.hostID`、`hostName`）。
    private(set) var hostID: String?
    private(set) var hostName: String?
    #if os(macOS)
    /// 它此刻的上下文（`CueState.context`，值班那台写、随状态同步）：Mac"运行情况"里上下文那一行（`CueContextLine`）只读它。
    private(set) var context: CueContext?
    #endif
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    /// 定时开着（`CueSchedulePage`）。
    var showsSchedules = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif

    /// `digest` 读不出来时为 nil（失败页盖住页面，空摘要不会露面）。
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

    /// 一次会话叫醒：叫醒记录的时刻（`at`）、本机第一次看到它的时刻（`seen`）、光从哪几个会话飞来。
    /// `seen` 是这次接力唯一的起点：光的起飞、到点点亮（接力层照它画）与小人醒（`seen` 加 `RelayFlight.wakeLanding`）都由它推出，
    /// 接力层不回报——它不在（Mac 主窗口关着、只剩输入条）时头像照样到点醒。
    struct Wake: Equatable {
        let at: Date
        let seen: Date
        let sessions: [String]
    }

    /// 你刚发出一句（`CueComposer`）：发出的光到点之前头像不露"在听"。同叫醒，由送出那一刻加 `RelayFlight.launchLanding` 推出，不等接力层回报。
    func sent(_ event: Send) { hold(event.beat, until: event.at.addingTimeInterval(RelayFlight.launchLanding)) }

    /// 跟随整个 App 那一份直到任务取消。
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
        lastYouSaid = digest.lastYou?.said
        // 推出的时刻每次都不同：内容一样就不写，免得读它的每一行跟着重算
        noteWake(digest.woke, catchingUp: catchingUp)
        let next = AppServices.cueNow(digest, at: moment, local: local).aged(to: .now)
        if !isPinned, !next.same(as: now) { show(next) }
        unread = digest.unread
        lastSaid = digest.lastSaid
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
