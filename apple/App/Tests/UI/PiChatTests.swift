import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话页对话的规则（iOS 会话页、Mac 会话详情共用）：消息怎么排、每轮回答上方的经过怎么写、发出的话什么时候是气泡、
/// 什么时候请 Mac 补写对话。
@MainActor
struct PiChatTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func message(_ seq: Int64, _ role: PiChatRole, _ text: String, tools: Int = 0, took: TimeInterval? = nil, delivery: UUID? = nil)
        -> PiChatMessage
    {
        PiChatMessage(
            sessionID: "s", entryID: "e\(seq)", seq: seq, role: role, text: text, at: start.addingTimeInterval(took ?? 0),
            toolCount: tools, roundStartedAt: took == nil ? nil : start, deliveryID: delivery)
    }

    @Test func 对话按先后排_你的话与Pi的回答各成一条() {
        let entries = PiChat.entries([message(1, .user, "跑一下测试"), message(2, .pi, "全部通过", tools: 3, took: 75)])
        #expect(entries.map(\.text) == ["跑一下测试", "全部通过"])
        #expect(entries.map(\.isUser) == [true, false])
    }

    @Test func 每轮回答上方写调了几个工具与做了多久() {
        #expect(PiChat.meta(message(2, .pi, "好了", tools: 5, took: 125)) == "运行了 5 个工具 · 2 分")
        #expect(PiChat.meta(message(2, .pi, "好了", tools: 1, took: 40)) == "运行了 1 个工具 · 40 秒")
        #expect(PiChat.meta(message(2, .pi, "好了", took: 8)) == "用时 8 秒")
        #expect(PiChat.meta(message(1, .user, "你好")) == nil)
    }

    @Test func 发出的话在对话里出现之前是气泡_出现之后不再显示() async throws {
        let app = TestApp()
        let recorder = PiStateRecorder(store: app.services.store, hostID: "mac")
        try await recorder.update(sessionID: "s", state: .settled, title: "s")
        let session = try #require(try await app.services.store.piSessionPage(.live).items.first?.state)
        let sent = try await app.services.requestMacDelivery("把断言也改了", to: session, mode: .send)
        let waiting = try await app.services.requestMacDelivery("再跑一遍", to: session, mode: .send)
        let answer = try await app.services.store.requestAnswer(
            PiAnswer(promptID: "p", value: .confirmed(true)), to: SendTarget(kind: .piSession, name: "s", ref: "s"), on: "mac")

        let shown = PiChat.outgoing([sent, waiting, answer], messages: [message(1, .user, "把断言也改了", delivery: sent.id)])

        #expect(shown.map(\.id) == [waiting.id])
    }

    @Test func 七天前活跃过又没有对话的会话_打开时请Mac补写() async throws {
        let now = start.addingTimeInterval(30 * 86_400)
        let old = PiSessionState(
            id: UUID(), sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(.ended), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: start, busySince: nil, createdAt: start, modifiedAt: start)
        var recent = old
        recent.stateSince = now.addingTimeInterval(-86_400)
        #expect(PiChat.needsTranscript(old, messages: [], now: now))
        #expect(!PiChat.needsTranscript(old, messages: [message(1, .user, "你好")], now: now))
        #expect(!PiChat.needsTranscript(recent, messages: [], now: now))
    }
}

/// 贴着最新（iOS 会话页、Mac 会话详情共用，规则同 use-stick-to-bottom）：只有用户自己滚走才解除贴底，回到最新处重新贴上；
/// 输入框长高、键盘弹出这类不是用户滚动带来的位移不解除。离最新处超过一屏出"回到最新"圆钮，离开后来了新内容圆钮带一个点。
struct ChatFollowTests {
    /// 一屏的高。
    private let screen: CGFloat = 700

    @Test func 贴着最新时来了新内容_没有圆钮也没有点() {
        var follow = ChatFollow()
        follow.contentChanged()
        #expect(follow.atNewest)
        #expect(!follow.showsJump)
        #expect(!follow.hasUnseen)
    }

    @Test func 离开不到一屏没有圆钮_超过一屏才有() {
        var follow = ChatFollow()
        follow.scrolled(distance: 300, screen: screen, byUser: true)
        #expect(!follow.atNewest)
        #expect(!follow.showsJump)
        follow.scrolled(distance: 900, screen: screen, byUser: true)
        #expect(follow.showsJump)
        follow.scrolled(distance: 10, screen: screen, byUser: true)
        #expect(follow.atNewest)
        #expect(!follow.showsJump)
    }

    @Test func 离开后来了新内容圆钮带点_回到最新点就没了() {
        var follow = ChatFollow()
        follow.scrolled(distance: 900, screen: screen, byUser: true)
        #expect(!follow.hasUnseen)
        follow.contentChanged()
        #expect(follow.hasUnseen)
        follow.scrolled(distance: 0, screen: screen, byUser: true)
        #expect(!follow.hasUnseen)
    }

    /// 顶栏：离开最新就让开，看历史期间怎么滑都不出现；点顶部唤出，再滑又让开；回到最新自动出现。
    @Test func 看历史时顶栏一直让开_点顶部唤出_再滑又让开_回到最新自动出现() {
        var follow = ChatFollow()
        #expect(follow.showsHeader)
        follow.scrolled(distance: 300, screen: screen, byUser: true)
        #expect(!follow.showsHeader)
        for distance in stride(from: 290.0, through: 40, by: -10) {
            follow.scrolled(distance: distance, screen: screen, byUser: true)
            #expect(!follow.showsHeader)
        }
        follow.reveal()
        #expect(follow.showsHeader)
        follow.scrolled(distance: 120, screen: screen, byUser: true)
        #expect(!follow.showsHeader)
        follow.scrolled(distance: 0, screen: screen, byUser: true)
        #expect(follow.showsHeader)
    }

    @Test func 输入框长高或键盘弹出带来的位移_不解除贴底() {
        var follow = ChatFollow()
        follow.scrolled(distance: 300, screen: screen, byUser: false)
        follow.contentChanged()
        #expect(follow.atNewest)
        #expect(!follow.hasUnseen)
    }
}

/// 对话末尾的子代理只有一行汇总：几个在跑、共几个，状态点按最需要注意的那个。
struct SubagentSummaryTests {
    @Test func 汇总在跑数与总数_状态点按最需要注意的那个() {
        let agents = [
            PiSubagentState(name: "研究", activity: .known(.working)),
            PiSubagentState(name: "审计", activity: .known(.waitingForUser)),
            PiSubagentState(name: "写测试", activity: .known(.working)),
        ]

        let summary = PiSubagentSummary(agents)

        #expect(summary?.running == 2)
        #expect(summary?.total == 3)
        #expect(summary?.lead == .known(.waitingForUser))
        #expect(PiSubagentSummary([]) == nil)
    }
}
