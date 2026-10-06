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
        #expect(PiChat.meta(message(2, .pi, "好了", tools: 5, took: 125)) == "运行了 5 个工具 · 2 分钟")
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

/// 对话的滚动跟随（iOS 会话页、Mac 会话详情共用）：停在底部时新内容到来跟着到底；往上翻离开底部后不跟，
/// 出现"新消息"按钮；点它或自己翻回底部恢复跟随。
struct ChatFollowTests {
    @Test func 停在底部时新内容到来跟着到底_不出按钮() {
        var follow = ChatFollow()
        #expect(follow.contentChanged() == true)
        #expect(!follow.showsJump)
    }

    @Test func 往上翻离开底部后新内容不跟_出现新消息按钮() {
        var follow = ChatFollow()
        follow.scrolled(atBottom: false)
        #expect(follow.contentChanged() == false)
        #expect(follow.showsJump)
    }

    @Test func 点按钮或自己翻回底部_恢复跟随_按钮消失() {
        var follow = ChatFollow()
        follow.scrolled(atBottom: false)
        _ = follow.contentChanged()
        follow.jumped()
        #expect(!follow.showsJump)
        #expect(follow.contentChanged() == true)

        follow.scrolled(atBottom: false)
        _ = follow.contentChanged()
        follow.scrolled(atBottom: true)
        #expect(!follow.showsJump)
        #expect(follow.contentChanged() == true)
    }

    @Test func 离开底部但没有新内容时不出按钮() {
        var follow = ChatFollow()
        follow.scrolled(atBottom: false)
        #expect(!follow.showsJump)
    }
}
