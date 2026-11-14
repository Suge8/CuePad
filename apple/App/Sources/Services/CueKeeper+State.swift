#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import Foundation

extension CueKeeper {
    enum Phase {
        /// 正在起大脑；参数是此前连续失败了几次
        case starting(failures: Int)
        case running(Shift)
        /// 第 n 次连续失败之后（原因），等着到 `at` 重起（`CueTiming.restartDelay`）；你发来消息、改了设置就马上再试。没有终态：快的重试用完转慢的，一直试下去
        case restarting(failures: Int, reason: ShownText, at: Date)
    }

    /// 大脑用的那几项设置：起大脑时取自设置，就地换了模型、强度跟着改；与库里的设置不同就去对上。
    nonisolated struct BrainSettings: Equatable, Sendable {
        var name: String
        var runtime: Open<AgentKind>
        var model: String?
        var effort: ThinkingLevel?
        var fast: Bool

        init(_ profile: CueProfile) {
            (name, runtime, model, effort, fast) = (profile.name, profile.runtime, profile.model, profile.effort?.known, profile.fast)
        }

        /// 换成 `wanted` 要换大脑（规则在 `CueProfile.needsNewBrain`）。
        func needsNewBrain(for wanted: BrainSettings) -> Bool { wanted.profile.needsNewBrain(from: profile) }

        private var profile: CueProfile { CueProfile(name: name, runtime: runtime, model: model, effort: effort.map(Open.known), fast: fast) }
    }

    struct Shift {
        let id: Int
        let brain: any HostedSession
        /// 起它时系统提示里重点那几条：变了就在下一轮前换班次（`outworn`）
        let pinned: [UUID]
        /// 这个大脑的会话已经接上（第一条输入带过视图）；没有时下一次醒来带上
        var primed = false
        let startedAt: Date
        var turn: Turn?
        /// 最近一次模型请求的上下文用量与窗口（token）：随状态写进库（`CueState.context`），各端读那一份
        var context: CueContext?
        /// 最近一次模型请求的时刻（报上下文用量的那一刻）：据此判断提示缓存过没过期（`renewDue`）
        var lastRequest: Date?
        /// 起好之前连续失败的次数：一轮做完清零
        var failures: Int
        /// 这一轮做完就换个班次（工具服务挂了、额度登录卡住换了 Agent）：下一句不再交给这个大脑
        var retiring = false
        /// 交给大脑、它还没报哪一轮接走（`TurnEvent.received`）的话：发送标识 → 其中你的消息与回答
        var handed: [UUID: [UUID]] = [:]
        /// 报了接走时没有在跑的一轮的你的话：接下来开始的那一轮接走的
        var taken: [UUID] = []
        /// 交出去、还没答上的你的话（接走它的一轮在跑、还没报接走、等着下一轮接）：大脑出问题时清掉送达、重起后重新交
        var unanswered: [UUID] { (turn?.delivered ?? []) + handed.values.flatMap(\.self) + taken }
    }

    /// 跨班次、跨 App 重启的对账进度：只放这台的本机事实（本机库的写入序号与次序、这台巡视与招呼过的）；还欠着的活都在库里（`Setback`）。
    nonisolated struct Progress: Codable {
        /// 基线：变化从这些写入序号之后算（`advanceBaseline`）；nil 是这台 Mac 还没值过班，从上班时库里的最新写入算起
        var marks: CueMarks?
        var patrolDay: String?
        var patrols = 0
        /// 巡视过的那段空闲（从你上次说话起）：冷巡视、热巡视各记各的，每段空闲各至多一次
        var patrolledIdle: Date?
        var warmedIdle: Date?
        /// 已为哪一次启用（`CueProfile.enabledAt`）招呼过：招呼的那一轮好好做完（或手上没事不用招呼）才记
        var greeted: Date?
        /// 做梦听他在会话里说的话听到哪了：交给它的最后一句的次序（`CueStore.said(after:limit:)` 的 `through`）；nil 是还没听过，从此刻听起（`dreams`）
        var heard: Int64?
        /// 额度、登录卡住后的绕行（`Detour`）；没在绕行为 nil
        var detour: Detour?

        init() {}

        /// 按字段解：一项解不开（结构改了、写坏了）只丢这一项并记错，变化基线等其余照用。
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            func field<T: Decodable>(_ key: CodingKeys) -> T? {
                do {
                    return try fields.decodeIfPresent(T.self, forKey: key)
                } catch {
                    CueKeeper.log.error("Cue 的对账进度里 \(key.stringValue, privacy: .public) 解不开，这一项丢掉：\(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            marks = field(.marks)
            patrolDay = field(.patrolDay)
            patrols = field(.patrols) ?? 0
            patrolledIdle = field(.patrolledIdle)
            warmedIdle = field(.warmedIdle)
            greeted = field(.greeted)
            detour = field(.detour)
            heard = field(.heard)
        }
    }

    /// 额度、登录卡住后的绕行：你设定的那家与它的模型、强度、fast（绕行前的设置），与这次卡住的几家。
    nonisolated struct Detour: Codable, Equatable, Sendable {
        struct Stuck: Codable, Equatable, Sendable {
            /// 卡住的时刻：轮流从最近卡住的那家后面数
            var at: Date
            /// 卡住时读到的重置时刻；读不到（登录、额度读不出、起不来）为 nil
            var resets: Date?
        }

        var runtime: AgentKind
        var model: String?
        var effort: ThinkingLevel?
        var fast: Bool
        var stuck: [AgentKind: Stuck] = [:]

        init(_ settings: BrainSettings, from runtime: AgentKind) {
            (self.runtime, model, effort, fast) = (runtime, settings.model, settings.effort, settings.fast)
        }

        /// 这家此刻该能用：这次没卡住，或读到的重置时刻已过。
        func open(_ kind: AgentKind, at now: Date) -> Bool {
            guard let stuck = stuck[kind] else { return true }
            return stuck.resets.map { $0 <= now } ?? false
        }

        /// 此刻该用哪家（唯一规则）：你设定的那家该能用就是它；此刻用的那家没卡住就留它；否则没卡过的那家，再否则重置已过的里最早的
        /// （这几种 `open`：该能用，马上换）；都不是就轮到最近卡住的那家后面的一家（碰运气，只在慢速周期到点时换）。
        /// 轮流与没卡过的按 Agent 的顺序从最近卡住的那家后面数。这台一家都没有为 nil。
        func next(from current: AgentKind, among kinds: [AgentKind], at now: Date) -> (kind: AgentKind, open: Bool)? {
            if kinds.contains(runtime), open(runtime, at: now) { return (runtime, true) }
            if stuck[current] == nil, kinds.contains(current) { return (current, true) }
            let last = stuck.max { $0.value.at < $1.value.at }?.key ?? current
            let split = kinds.firstIndex(of: last).map { $0 + 1 } ?? 0
            let order = kinds[split...] + kinds[..<split]
            if let fresh = order.first(where: { stuck[$0] == nil }) { return (fresh, true) }
            let passed = order.compactMap { kind in stuck[kind]?.resets.flatMap { $0 <= now ? (kind, $0) : nil } }
            if let earliest = passed.min(by: { $0.1 < $1.1 }) { return (earliest.0, true) }
            return order.first.map { ($0, false) }
        }

        /// 换到这家时设置写成什么：你设定的那家照原样；别的那家用它自己的默认模型（模型名各家不通用）、fast 关，强度照你设定的。
        func apply(_ kind: AgentKind, to profile: inout CueProfile) {
            let home = kind == runtime
            profile.runtime = .known(kind)
            (profile.model, profile.effort, profile.fast) = (home ? model : nil, effort.map(Open.known), home && fast)
        }

        /// 设置还是绕行写下的样子；不是就是你或 Cue 后来改了（后来的选择就是你设定的，不再绕行）。
        func wrote(_ profile: CueProfile) -> Bool {
            guard let kind = profile.runtime.known else { return false }
            var written = profile
            apply(kind, to: &written)
            return written == profile
        }

        /// 下一个还没到的重置时刻：到点时对一次账，该能用的那家马上换过去（`CueKeeper.alarm`）。
        func nextReset(after now: Date) -> Date? { stuck.values.compactMap(\.resets).filter { $0 > now }.min() }
    }

    struct Turn {
        /// 这一轮是在回答你：你发起的，或中途插进了你的话。提不提示你、写不写回复都看它
        var answersYou: Bool
        /// 这一轮的经过：醒来的时刻（Cue 在这之后用 tell 说过话，自己醒来的刚启用那一轮最后就不再写招呼）、在用的工具、报的错都在这里
        var round: CueRound
        /// Cue 自己醒来（不是你发来消息）的这一轮为什么醒（出错要退避、重试同一次醒来）；你发起的为 nil
        var selfStarted: CueWake?
        /// 这一轮接走的你的消息与回答（大脑报的，`TurnEvent.received`）。Cue 自己醒来的一轮里有它，就是中途插进了你的话
        var delivered: [UUID] = []
        /// 大脑此刻正在说的话：做完时还留着的就是这一轮的回复
        var speaking: LiveDraft?
        /// 醒来时读到的写入序号（读变化之前取）：这一轮做完且没出错，会话的动静从它之后算
        var mark: Int?
        /// 会话停下叫醒的这一轮报给 Cue 的那几次停下（歇着、等回答、出错）：做完时还没给去处的 CuePad 替它留给他回（`CueKeeper.leaveUnattended`）
        var stops: [CueLeft] = []
        /// 这一轮出错后换了 Agent：交出去的你的话退回、自己醒来的那次马上重来，都交给新的大脑
        var replay = false

        /// 最后的话写不写进对话：回答你的一轮、刚启用的招呼照写；Cue 自己醒来的其余各轮一律不写，Cue 页照它的动作写这一轮（`CueRound.process`）。
        var writesReply: Bool { answersYou || selfStarted == .enabled }

        /// 署名只跟着上面两条走：写进对话的是 Cue 的话，其余是这一轮的经过（`note`，没有正文）
        var author: CueAuthor { writesReply ? .cue : .note }
    }

    /// 出错后要重来的一件（每个醒来原因至多一条，只在内存），承接它的一轮好好做完才放下。还欠着什么只看库：定时是过点的那一行、刚启用是没招呼过的那一次启用、
    /// 你的话是退回没送达的那几句；这里只记什么时候再试。会话动静与巡视（`supersedable`）的活从库里的变化重读得出，重试一次后可被新变化取代；
    /// 其余按退避重来。额度、登录卡住（`stuck`）只按慢速周期重来，新变化不替代、不催它。重启、换手后从头算：库里还欠着的马上再来。
    nonisolated struct Setback: Equatable, Sendable {
        /// 一件重来走到哪了：有它就是出过错（`CueKeeper.firstError`）
        enum Stage: Equatable, Sendable {
            /// 第一次出错：到点再来一次（`CueTiming.retryWake`）
            case again(at: Date)
            /// 再错，或额度、登录卡住（`stuck`）：按慢速周期一直重来，这是第 `stalls` 轮（`CueTiming.slowDelay`）
            case slow(at: Date, stalls: Int, stuck: Bool)
            /// 会话动静与巡视再错，或重来已交出去：等新变化取代
            case awaitingChange
        }

        var stage: Stage
        var wake: CueWake
        /// 出错时变化里最新的写入序号（等子代理停住按时刻认，不算）与出错的时刻：之后有更新的才是新变化。读不到序号为 nil，只按时刻认
        var latest: Int?
        var since: Date
        /// 上一轮的错：重来的那一轮随信封交给大脑（`CueEnvelope.Input.retrying`）
        var failure: String?
        /// 你的话（`.message`）：这次退回、等它到点再交的几句；之后新来的话不等，一起交
        var held: Set<UUID> = []

        var retryAt: Date? {
            switch stage {
            case .again(let at), .slow(let at, _, _): at
            case .awaitingChange: nil
            }
        }

        var stuck: Bool {
            if case .slow(_, _, true) = stage { true } else { false }
        }

        var stalls: Int {
            if case .slow(_, let stalls, _) = stage { stalls } else { 0 }
        }

        var supersedable: Bool { Self.supersedable(wake) }

        static func supersedable(_ wake: CueWake) -> Bool {
            switch wake {
            case .sessionActivity, .idle: true
            case .enabled, .message, .schedule: false
            }
        }

        /// 按时刻等的改成 `date` 到点；等新变化的不动。
        mutating func due(_ date: Date) {
            switch stage {
            case .again: stage = .again(at: date)
            case .slow(_, let stalls, let stuck): stage = .slow(at: date, stalls: stalls, stuck: stuck)
            case .awaitingChange: break
            }
        }
    }

    nonisolated enum Input: Sendable {
        case kick, stop
        case brain(Int, TurnEvent)
        /// 对一次账，对完接着 `done`：要确定值班看过此刻的库与钟的一方显式交（测试在负向断言前）
        case settle(CheckedContinuation<Void, Never>)
    }

    /// 触发对账的读数：变了就对一次账（内容不用，对账自己读）。对话只取对账用到的：待交给它的你的话与回答、你最近一句的时刻（巡视从它算空闲）；
    /// Cue 自己写的经过、回复不叫醒对账。记忆的版本在内：提醒在记忆里，记下、清掉都要重排定时器。
    /// 看板只取对账用到的那一点：在不在做事（变了才可能该排巡视）；其余变化（会话歇下、事做完）都在写入序号里。
    nonisolated struct Signal: Equatable, Sendable {
        var toDeliver: [UUID]
        var lastYou: Date?
        var active: Bool
        var memory: CueMemoryVersion
        var profile: CueProfile?
        /// 本机最近一次写入的序号（`CueStore.lastWrite`）：会话状态与收尾，卡片的完成与层级，投送请求的状态一变它就变
        /// （晚到的变化事件时刻也可能更早，只有写入序号一定跟着变）；会话的其余列（说明、上下文、子代理的动作）与会话里的消息怎么变都不叫醒对账
        var written: Int
        var runtime: [Date]
    }
}

extension CueWake {
    /// 定时醒来的那几次；别的醒来原因没有
    var fires: [CueFire] { if case .schedule(let fires) = self { fires } else { [] } }
}
#endif
