#if DEBUG
import CueStore
import Foundation

extension DebugScene {
    // 每一轮的经过（同值班的管理器写下的样子，`CueActivity.item`）：碰到的任务与会话带着名字与 id，点它去那里
    static func step(
        _ kind: PiChatMessage.Tools.Kind, _ target: String, _ task: Card? = nil, session: String? = nil
    ) -> PiChatMessage.Tools.Item {
        .init(
            kind: kind, target: target, task: task?.id, name: task?.heading ?? session,
            session: session.map(PiSessionState.recordID(sessionID:)))
    }
    static func process(_ items: PiChatMessage.Tools.Item...) -> PiChatMessage.Tools {
        var tools = PiChatMessage.Tools()
        for item in items { tools.record(item) }
        return tools
    }
    static func stirred(_ kind: CueChange.Kind, _ session: String) -> CueWake { .sessionActivity([CueStir(kind: kind, session: session)]) }

    /// `-CuePadCuePresence` 各档在公共对话之上再写的那一段。
    static func seedPresence(
        _ presence: String?, store: CueStore, asked: CueMessage, order: Card?, panel: Card?, importing: Card?, context: CueContext,
        you: (String) async throws -> Void
    ) async throws {
        switch presence {
        case "answered":
            _ = try await store.endCueQuestion(asked.id, .answered(CueAsk.once))
            try await you(String(localized: "顺便看看登录回调那个超时", table: "Demo"))
            let login = try await store.createTask(String(localized: "登录回调超时", table: "Demo"), in: order?.projectID ?? Project.defaultID)
            _ = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, String(localized: "看板", table: "Demo")), step(.add, String(localized: "建任务「登录回调超时」", table: "Demo"), login), step(.start, String(localized: "开工「登录回调超时」", table: "Demo"), login),
                step(.talk, String(localized: "对「登录回调超时」说：先复现回调等 token 刷新时一直挂着", table: "Demo"), login),
                step(.talk, String(localized: "对「发言轮次乱序」说：先停一下，等登录回调修好再部署", table: "Demo"), order),
                step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel), step(.done, String(localized: "做完「README 截图」", table: "Demo"), panel),
                step(.stop, String(localized: "停下「billing」", table: "Demo"), session: "billing"), step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing)))
            _ = try await store.addCueMessage(.cue, text: String(localized: "好，我先让 auth 会话复现一下。", table: "Demo"))
            _ = try await store.addCueMessage(.cue, text: String(localized: "复现了：回调里等 token 刷新时没设超时，网络慢时会一直挂着。改成 10 秒超时、超时后回登录页重新授权，测试在跑。", table: "Demo"))
        case "thinking":
            try await you(String(localized: "顺便看看登录回调那个超时", table: "Demo"))
            try await store.setCueState(.thinking, context: context)
        case "tool":
            try await you(String(localized: "顺便看看登录回调那个超时", table: "Demo"))
            let login = try await store.createTask(String(localized: "登录回调超时", table: "Demo"), in: order?.projectID ?? Project.defaultID)
            let row = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, String(localized: "看板", table: "Demo")), step(.search, String(localized: "登录回调 超时", table: "Demo")), step(.add, String(localized: "建任务「登录回调超时」", table: "Demo"), login), step(.start, String(localized: "开工「登录回调超时」", table: "Demo"), login),
                step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing), step(.leave, String(localized: "「notes」留给你回", table: "Demo"), session: "notes")))
            try await store.setCueState(.tool, step: .init(kind: .talk, name: login.heading, task: login.id), round: row, context: context)
        case "woke":
            // Cue 自己醒来的一轮还在跑：叫醒它的那一行下面挂这一轮的经过（碰到 4 处，连同在跑那一行至多 4 行），末行是此刻在做的
            let row = try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: process(
                step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order), step(.talk, String(localized: "对「发言轮次乱序」说：重连用例补完把测试全跑一遍", table: "Demo"), order),
                step(.edit, String(localized: "改「导入旧数据」", table: "Demo"), importing), step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing),
                step(.done, String(localized: "做完「README 截图」", table: "Demo"), panel),
                step(.leave, String(localized: "「notes」留给你回", table: "Demo"), session: "notes")), wake: stirred(.settled, "atlas"))
            try await store.setCueState(.tool, step: .init(kind: .stop, name: "billing", session: PiSessionState.recordID(sessionID: "billing")), round: row, context: context)
        case "sending":
            _ = try await store.addCueMessage(.you, text: String(localized: "顺便看看登录回调那个超时", table: "Demo"))
        case "away":
            _ = try await store.endCueQuestion(asked.id, .answered(CueAsk.once))
            try await you(goingAway)
            try await seedAway(store)
        case "asleep":
            // 两分钟前说的、一直没交出去（之前的对话挪得更早）
            try await store.seedAgeCueMessages(by: 480)
            _ = try await store.addCueMessage(.you, text: String(localized: "顺便看看登录回调那个超时", table: "Demo"))
            try await store.seedAgeCueMessages(by: 120)
        default: break
        }
    }
}
#endif
