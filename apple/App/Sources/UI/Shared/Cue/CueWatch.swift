import CueStore
import Foundation
import Observation

/// 一个窗口里 Cue 的现状和 Cue 页的输入草稿：侧栏、底栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
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
    /// 能对它说话：启用了（住的那台 Mac 不在线也能说，开机后它会读到）。单列一项：输入框只看它，不随在想、用工具重算。
    private(set) var canHear = false
    /// "等你 N"（`CueDigest.waiting`）。
    private(set) var waiting = 0
    private(set) var lastSaid: String?
    private(set) var lastSaidDone = false
    /// 它住的那台 Mac 与它的名字（`CueDigest.hostID`、`hostName`）。
    private(set) var hostID: String?
    private(set) var hostName: String?
    /// 它此刻的上下文（`CueState.context`，值班那台写、随状态同步）：上下文用量（`CueContextCard`）只读它。
    private(set) var context: CueContext?
    /// 在跑的这一轮的经过那一行（`CueState.round`）。
    private(set) var round: UUID?
    /// 此刻叫醒它的这一轮（`CueState.woke`）。这个窗口读到的第一份不算（App 刚打开、窗口刚开时已有的叫醒不是此刻发生的），
    /// 之后 `at` 变成新的就是又被叫醒了一次（`CueRelayStage`）。
    private(set) var woke: CueWoke?
    /// 第一份里已有的那次叫醒的时刻（`woke` 不算它）。
    @ObservationIgnored private let stale: Date?
    /// 此刻 Cue 交给会话的这一批（`Reading.relays` 里比上一批新的）。窗口读到的第一份里已有的不算，同 `woke`。
    private(set) var relay: CueRelay?
    /// 已经算过的最新一条交给的时刻：第一份里最新的那条，之后是上一批里最新的。
    @ObservationIgnored private var relayedThrough: Date?
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
        var relays: [CueRelay.Handed]

        static func read(from store: isolated CueStore) throws -> Reading {
            Reading(digest: try CueDigest.read(from: store), relays: try CueRelay.Handed.read(from: store))
        }
    }

    init(_ start: Snapshot<Reading>?, at moment: Speech.Moment) {
        self.start = start
        stale = start?.value.digest.state?.woke?.at
        relayedThrough = start?.value.relays.map(\.at).max()
        if let reading = start?.value { apply(reading, at: moment) }
    }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: waiting, composing: composing, justDone: lastSaidDone)
    }

    /// `session` 此刻在接力（叫醒 Cue 的、Cue 交给的）：它的状态标挂锚（`relaySpot`）。
    func relays(session: String) -> Bool {
        woke?.sessions.contains(session) == true || relay?.ends.contains { $0.session == session } == true
    }

    /// Cue 此刻交给的是这件任务（开新会话、带着它说话）。
    func relays(task: UUID) -> Bool { relay?.ends.contains { $0.task == task } == true }

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
        set(\.waiting, digest.waiting)
        set(\.lastSaid, digest.lastSaid)
        set(\.lastSaidDone, digest.lastSaidDone)
        set(\.hostID, digest.hostID)
        set(\.hostName, digest.hostName)
        set(\.round, digest.state?.round)
        set(\.context, digest.state?.context)
        let woke = digest.state?.woke
        set(\.woke, woke?.at == stale ? nil : woke)
        let since = relayedThrough ?? .distantPast
        let fresh = reading.relays.filter { $0.at > since }
        if let latest = fresh.map(\.at).max() {
            relayedThrough = latest
            relay = CueRelay(at: latest, ends: fresh.sorted { $0.at > $1.at }.map(\.end))
        }
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<CueWatch, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}
