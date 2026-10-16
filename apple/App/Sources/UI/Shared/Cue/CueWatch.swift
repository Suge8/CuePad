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
    /// 在跑的这一轮的经过那一行（`CueState.round`）。
    private(set) var round: UUID?
    /// 此刻叫醒它的这一轮（`CueState.woke`）。这个窗口读到的第一份不算（App 刚打开、窗口刚开时已有的叫醒不是此刻发生的），
    /// 之后 `at` 变成新的就是又被叫醒了一次（`CueWakeStage`）。
    private(set) var woke: CueWoke?
    /// 第一份里已有的那次叫醒的时刻（`woke` 不算它）。
    @ObservationIgnored private let stale: Date?
    /// 当场读到的第一份（读不出来时为 nil，失败页盖住页面）：`follow` 从它接着订阅。
    @ObservationIgnored private let start: Snapshot<CueDigest>?
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif

    init(_ start: Snapshot<CueDigest>?, at moment: Speech.Moment) {
        self.start = start
        stale = start?.value.state?.woke?.at
        if let digest = start?.value { apply(digest, at: moment) }
    }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: waiting, composing: composing, justDone: lastSaidDone)
    }

    /// 跟随资料库与此刻直到任务取消。
    func follow(_ services: AppServices) async throws {
        for try await (digest, moment) in services.observeTimed(from: start, { try CueDigest.read(from: $0) }) {
            apply(digest, at: moment)
        }
    }

    private func apply(_ digest: CueDigest, at moment: Speech.Moment) {
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
        let woke = digest.state?.woke
        set(\.woke, woke?.at == stale ? nil : woke)
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<CueWatch, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}
