#if os(macOS)
import CueAgent
import CuePi
import CueStore
import Foundation

extension CueKeeper {
    enum Phase {
        /// 正在起大脑；参数是此前连续失败了几次
        case starting(failures: Int)
        case running(Shift)
        /// 第 n 次连续失败之后，等着重起
        case restarting(Int)
        /// 次数用完，停在起不来（原因）；你的下一条消息再试
        case stuck(String)
    }

    /// 大脑用的那几项设置：起大脑时取自设置，就地换了模型、强度跟着改；与库里的设置不同就去对上。
    nonisolated struct BrainSettings: Equatable, Sendable {
        var name: String
        var runtime: Open<AgentKind>
        var model: String?
        var effort: PiThinkingLevel?

        init(_ profile: CueProfile) {
            (name, runtime, model, effort) = (profile.name, profile.runtime, profile.model, profile.effort?.known)
        }

        /// 换成 `wanted` 要换大脑：名字在系统提示里、Agent 是另一个进程；模型、强度回到运行时默认就地也做不到。
        func needsNewBrain(for wanted: BrainSettings) -> Bool {
            wanted.name != name || wanted.runtime != runtime || (wanted.model == nil && model != nil) || (wanted.effort == nil && effort != nil)
        }
    }

    struct Shift {
        let id: Int
        let brain: any CueBrain
        /// 起它时系统提示里一直记着的那几条：换新时变了就换班次（`renewDue`）
        let pinned: [UUID]
        /// 这个大脑的会话已经接上（第一条输入带过视图）；没有时下一次醒来带上
        var primed = false
        let startedAt = Date.now
        /// 这个会话从何时起（开新会话时改）：上下文用量从这里算
        var sessionSince = Date.now
        var turn: Turn?
        /// 最近一次模型请求的上下文用量与窗口（token）：随状态写进库（`CueState.context`），各端读那一份
        var context: CueContext?
        /// 最近一次模型请求的时刻（报上下文用量的那一刻）：据此判断提示缓存过没过期（`renewDue`）
        var lastRequest: Date?
        /// 这个班次里请过合并的块（同一块只请一次）
        var mergesTried: Set<[Int]> = []
        /// 起好之前连续失败的次数：一轮做完清零
        var failures: Int
    }

    /// 跨班次、跨 App 重启的对账进度（本机，只给这台 Mac 的管理器用）。
    nonisolated struct Progress: Codable {
        /// 基线：变化从这些写入序号之后算（`advanceBaseline`）；nil 是这台 Mac 还没值过班，从上班时库里的最新写入算起
        var marks: CueMarks?
        var patrolDay: String?
        var patrols = 0
        /// 巡视过的那段空闲（从你上次说话起）
        var patrolledIdle: Date?
        /// 已为哪一次启用（`CueProfile.enabledAt`）醒来过
        var greeted: Date?
        /// 归他、等他离开再报的停下：会话 id → 那次停下的起点（`CueChanges.held`）
        var held: [String: Date] = [:]
    }

    struct Turn {
        /// 回复写成谁的
        var author: CueAuthor
        /// 这一轮的经过：醒来的时刻（Cue 在这之后用 tell 说过话，自己醒来的这一轮最后就不再写 note）、在用的工具、报的错都在这里
        var round: CueRound
        /// Cue 自己醒来（不是你发来消息）的这一轮为什么醒、附了什么（出错要退避、重试同一次醒来）；你发起的为 nil
        var selfStarted: (wake: CueWake, extra: String?)?
        /// 这一轮里交出去的你的消息与回答：大脑中途退出时清掉送达。Cue 自己醒来的一轮里有它，就是中途插进了你的话
        var delivered: [UUID] = []
        /// 大脑此刻正在说的话：做完时还留着的就是这一轮的回复
        var speaking: PiDraft?
        /// 醒来时读到的写入序号（读变化之前取）：这一轮做完且没出错，会话的动静从它之后算
        var mark: Int?
        /// 这一轮做完且没出错后，还要等他离开再报的那几次停下（`Progress.held`）：这一轮报了的不再记，没做完下次照样报
        var held: [String: Date]?

        /// 这一轮是在回答你：你发起的、中途插进了你的话，或写成 cue 的（中途插过你的话、出错后重试的那一轮）。不是的（Cue 自己醒来、
        /// 含刚启用）已经用 tell 对你说过话，最后的回复就不再写
        var answersYou: Bool {
            guard let wake = selfStarted?.wake else { return true }
            return !delivered.isEmpty || (wake != .enabled && author == .cue)
        }

        /// 最后的话写不写进对话：回答你的一轮、刚启用的招呼照写；Cue 自己醒来的其余各轮没动过手（`CueRound.acted`）就不写——
        /// 系统提示里"什么都没做就不写"只在这里定。
        var writesReply: Bool { answersYou || selfStarted?.wake == .enabled || round.acted }
    }

    /// Cue 自己醒来的一轮出错了：之后自己醒来先等着，直到 `retryAt`（只一次）或有新变化（写入序号大于 `latest`，或在 `since` 之后才到的等子代理停住）。
    struct Setback {
        var latest: Int?
        var since: Date
        var retryAt: Date?
        var wake: CueWake
        var extra: String?
        var author: CueAuthor
    }

    nonisolated enum Input: Sendable {
        case kick, retry, stop
        case brain(Int, CueBrainEvent)
    }

    /// 触发对账的读数：变了就对一次账（内容不用，对账自己读）。记忆的版本在内：记一条、忘掉、合并都可能改变待合并的块。
    /// 看板只取对账用到的那一点：在不在做事（变了才可能该排巡视）；其余变化（会话歇下、事做完）都在写入序号里。
    nonisolated struct Signal: Equatable, Sendable {
        var messages: [CueMessage]
        var active: Bool
        var memory: CueMemoryVersion
        var profile: CueProfile?
        /// 各设备开着的会话（`Viewer`）：他离开了在场的会话，要再报给 Cue
        var viewing: [String]
        /// 本机最近一次写入的序号（`CueStore.lastWrite`）：会话状态、问答，卡片的完成与层级，投送请求的状态，对话里的新消息一变它就变
        /// （晚到的变化事件时刻也可能更早，只有写入序号一定跟着变）；会话的其余列（说明、上下文、子代理的动作）怎么变都不叫醒对账
        var written: Int
    }
}
#endif
