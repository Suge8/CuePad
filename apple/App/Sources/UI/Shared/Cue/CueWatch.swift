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
    /// 在路上或在做事（`CuePresence.shown` 有值）与此刻的表情（不算你正在写，`mood(composing:)`）：标签图标只看这两项。
    private(set) var busy = false
    private(set) var expression = CueMood.sleeping
    /// Cue 此刻（`CueNow`）：Cue 那一行的第二行只读它；内容变了才换（推出的时刻不算）。
    private(set) var now = CueNow.empty
    /// "等你 M"（`CueDigest.waiting`，拍板加待回复）：角标、入口的点与面板里等你那一行只读它，不随 Cue 此刻的别的变化重算。
    private(set) var waiting = 0
    /// "推进中 N"（`CueDigest.advancing`）：侧栏进展那一行只读它与 `waiting`。
    private(set) var advancing = 0
    /// 新消息有几条（`CueDigest.unread`）。
    private(set) var unread = 0
    /// 它最近一句（`CueDigest.lastSaid`）：只有 Mac 侧栏名片的气泡读。
    private(set) var lastSaid: String?
    /// 它运行的那台 Mac 与它的名字（`CueDigest.hostID`、`hostName`）。
    private(set) var hostID: String?
    private(set) var hostName: String?
    /// 说它在哪台运行的那一格（手机设置里 Cue 那一行）：启用了是那台的名字，没启用写"没启用"。
    var home: String? { canHear ? hostName : "没启用" }
    /// 它此刻的上下文（`CueState.context`，值班那台写、随状态同步）：上下文那一行（`CueContextLine`）只读它。
    private(set) var context: CueContext?
    /// 在跑的这一轮的经过那一行（`CueState.round`）。
    private(set) var round: UUID?
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif

    /// `digest` 读不出来时为 nil（失败页盖住页面，空摘要不会露面）。
    init(_ digest: CueDigest?, at moment: Speech.Moment, local: CueNow.Local) {
        if let digest { apply(digest, at: moment, local: local) }
    }

    /// 你正在写时：闲着没人等的 Cue 在听（"刚做完"让给它）；不在写就是此刻的表情。
    func mood(composing: Bool) -> CueMood {
        composing ? CueMood.of(presence, waiting: waiting, composing: true) : expression
    }

    /// 跟随整个 App 那一份直到任务取消。
    func follow(_ services: AppServices) async throws {
        for try await seen in services.cueUpdates() {
            apply(seen.read.digest, at: seen.moment, local: seen.local)
        }
    }

    private func apply(_ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local) {
        name = digest.name
        let presence = CuePresence.derive(digest, at: moment)
        self.presence = presence
        canHear = presence != .disabled
        sending = if case .sending = presence { true } else { false }
        lastYouSaid = digest.lastYou?.said
        busy = presence.shown != nil
        // 推出的时刻每次都不同：内容一样就不写，免得读它的每一行跟着重算
        let next = AppServices.cueNow(digest, at: moment, local: local)
        if !isPinned {
            expression = CueMood.of(presence, waiting: digest.waiting, justDone: digest.lastSaidDone)
            if !next.same(as: now) { now = next }
        }
        waiting = digest.waiting
        advancing = digest.advancing
        unread = digest.unread
        lastSaid = digest.lastSaid
        hostID = digest.hostID
        hostName = digest.hostName
        round = digest.state?.round
        context = digest.state?.context
    }

    /// 调试画面手动换的 Cue 此刻（`-CuePadCueCycle` 轮流走各态，`DebugScene.cueNowTourIfAsked`）：换过就不再随库变，头像的表情跟着它。
    @ObservationIgnored private var isPinned = false

    func pin(_ next: CueNow) {
        isPinned = true
        now = next
        expression = next.mood
    }
}
