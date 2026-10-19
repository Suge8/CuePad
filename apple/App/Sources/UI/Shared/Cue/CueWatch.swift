import CueStore
import Foundation
import Observation

/// 一个窗口里 Cue 的现状和 Cue 页的输入草稿：侧栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
/// 事实只有库里那一页摘要（`CueDigest`）与此刻（`SpeechClock`）；这里按读的人要的粒度把它拆成一项项存下，每项只在变了时才写——
/// Observation 按存储属性追踪，存整份摘要时任何一项变（在想→用工具、等你数、最近一句……），读名字的每一行会话（`Workspace.cueOnDuty`）、
/// 书架与侧栏都要跟着重算。
/// 在不在、话在不在路上随库与此刻重算：它那台 Mac 的在线期限由订阅到点重读（`CueStore.macOnline`），你最近一句的时限与同步通断由
/// 此刻给，这里不另计时。
/// 第一份在建工作区时当场读到（`Workspace.init`），之后从它接着订阅：没有"还没读到"时的默认现状。
/// 读的是摘要加 Cue 交给会话的那几条（`Reading`）：交给只有窗口要，不放进摘要——小组件也读摘要，投送请求一变它不必跟着重读。
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
    /// 在路上或在做事（`CuePresence.shown` 有值）与此刻的表情（不算你正在写，`mood(composing:)`）：标签图标只看这两项。
    private(set) var busy = false
    private(set) var expression = CueMood.sleeping
    /// "等你 N"（`CueDigest.waiting`）。
    private(set) var waiting = 0
    /// 新消息有几条（`CueDigest.unread`）。
    private(set) var unread = 0
    private(set) var lastSaid: String?
    /// 它运行的那台 Mac 与它的名字（`CueDigest.hostID`、`hostName`）。
    private(set) var hostID: String?
    private(set) var hostName: String?
    /// 说它在哪台运行的那一格（Cue 面板的齿轮旁、手机设置里 Cue 那一行）：启用了是那台的名字，没启用写"没启用"。
    var home: String? { canHear ? hostName : "没启用" }
    /// 它此刻的上下文（`CueState.context`，值班那台写、随状态同步）：上下文用量（`CueContextCard`）只读它。
    private(set) var context: CueContext?
    /// 在跑的这一轮的经过那一行（`CueState.round`）。
    private(set) var round: UUID?
    /// 最近一次接力（`CueRelayStage`）：比已算过的更新的叫醒（`CueState.woke`）或交给（`Reading.relays`），`at` 变成新的就播一次。
    /// 这个窗口读到的第一份里已有的都不算（App 刚打开、窗口刚开时已有的不是此刻发生的）。同一次读到两种都新时只播更新的那种。
    private(set) var flight: CueFlight?
    /// 已经算过的最新时刻（叫醒与交给同一条时间线）。
    @ObservationIgnored private var seen: Date?
    /// 当场读到的第一份（读不出来时为 nil，失败页盖住页面）：`follow` 从它接着订阅。
    @ObservationIgnored private let start: Snapshot<Reading>?
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif

    /// 一次读到的：Cue 的摘要与它交给会话的那几条。
    nonisolated struct Reading: Equatable, Sendable {
        var digest: CueDigest
        var relays: [CueFlight.Handed]

        static func read(from store: isolated CueStore) throws -> Reading {
            Reading(digest: try CueDigest.read(from: store), relays: try CueFlight.Handed.read(from: store))
        }

        /// 比 `seen` 新的那一次接力；没有为 nil。
        func flight(after seen: Date?) -> CueFlight? {
            let since = seen ?? .distantPast
            let woke = digest.state?.woke.flatMap { $0.at > since ? CueFlight(direction: .wake, at: $0.at, ends: $0.sessions.map { RelayEnd(session: $0) }) : nil }
            let fresh = relays.filter { $0.at > since }.sorted { $0.at > $1.at }
            let relay = fresh.first.map { CueFlight(direction: .relay, at: $0.at, ends: fresh.map(\.end)) }
            return [woke, relay].compactMap { $0 }.max { $0.at < $1.at }
        }

        /// 读到的最新时刻。
        var latest: Date? { ([digest.state?.woke?.at] + relays.map(\.at)).compactMap { $0 }.max() }
    }

    init(_ start: Snapshot<Reading>?, at moment: Speech.Moment) {
        self.start = start
        seen = start?.value.latest
        if let reading = start?.value { apply(reading, at: moment) }
    }

    /// 你正在写时：闲着没人等的 Cue 在听（"刚做完"让给它）；不在写就是此刻的表情。
    func mood(composing: Bool) -> CueMood {
        composing ? CueMood.of(presence, waiting: waiting, composing: true) : expression
    }

    /// `session` 在最近一次接力里：它的状态标挂锚（`relaySpot`）。
    func relays(session: String) -> Bool { flight?.ends.contains { $0.session == session } == true }

    /// 最近一次接力交给的是这件任务（开新会话、带着它说话）。
    func relays(task: UUID) -> Bool { flight?.ends.contains { $0.task == task } == true }

    /// 跟随资料库与此刻直到任务取消。
    func follow(_ services: AppServices) async throws {
        for try await (reading, moment) in services.observeTimed(from: start, { try Reading.read(from: $0) }) {
            apply(reading, at: moment)
        }
    }

    private func apply(_ reading: Reading, at moment: Speech.Moment) {
        let digest = reading.digest
        set(\.name, digest.name)
        let presence = CuePresence.derive(digest, at: moment)
        set(\.presence, presence)
        set(\.canHear, presence != .disabled)
        set(\.sending, presence == .sending)
        set(\.lastYouSaid, digest.lastYou?.said)
        set(\.busy, presence.shown != nil)
        set(\.expression, CueMood.of(presence, waiting: digest.waiting, justDone: digest.lastSaidDone))
        set(\.waiting, digest.waiting)
        set(\.unread, digest.unread)
        set(\.lastSaid, digest.lastSaid)
        set(\.hostID, digest.hostID)
        set(\.hostName, digest.hostName)
        set(\.round, digest.state?.round)
        set(\.context, digest.state?.context)
        if let next = reading.flight(after: seen) {
            seen = reading.latest
            flight = next
        }
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<CueWatch, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}
