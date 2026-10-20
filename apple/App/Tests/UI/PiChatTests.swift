import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话页对话的规则（iOS 会话页、Mac 会话详情共用）：消息怎么排、每轮回答上方的经过怎么写、发出的话什么时候是气泡、
/// 什么时候请 Mac 补写对话。
struct PiChatTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func message(_ seq: Int64, _ role: PiChatRole, _ text: String, tools: PiChatMessage.Tools? = nil, took: TimeInterval? = nil, delivery: UUID? = nil)
        -> PiChatMessage
    {
        PiChatMessage(
            sessionID: "s", entryID: "e\(seq)", seq: seq, role: role, text: text, at: start.addingTimeInterval(took ?? 0),
            tools: tools, roundStartedAt: took == nil ? nil : start, deliveryID: delivery)
    }

    /// 系统行有三种：压缩是上下文换了（分隔、刻度滑条上一个点），停下与拒绝只是这一轮怎么结束的（不是分隔、不打点）。
    @Test func 只有压缩是换上下文_停下与拒绝不是() {
        let entries = PiChat.entries([
            message(1, .user, "第一问"), message(2, .system, "已停止"), message(3, .user, "第二问"), message(4, .system, "已拒绝"),
            message(5, .system, "已压缩上下文"),
        ])

        #expect(ChatScrubber.marks(entries).map { "\($0.kind)" } == ["said", "said", "boundary"])
        #expect(entries.map(\.role) == [.user, .notice(.stopped), .user, .notice(.declined), .notice(.compacted)])
    }

    /// 发出的话在对话里出现之前是气泡，出现之后不再显示。对话只来自会话文件：作答与斜杠命令不是"你发出的话"，不挂气泡
    /// （/compact、/name、/reload 在会话文件里没有带请求 id 的用户消息，挂了就永远换不掉）。
    @Test func 发出的话在对话里出现之前是气泡_出现之后不再显示_作答与斜杠命令不是气泡() async throws {
        let app = TestApp()
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s", state: .settled, title: "s")
        let session = try #require(try await store.piSessionPage(.live).items.first?.state)
        let sent = try await store.requestDelivery("把断言也改了", to: session.target, on: session.hostID, mode: .send)
        let waiting = try await store.requestDelivery("再跑一遍", to: session.target, on: session.hostID, mode: .send)
        let answer = try await store.requestAnswer(PiAnswer(promptID: "p", value: .confirmed(true)), to: session.target, on: "mac")
        let command = try await store.requestDelivery("/compact", to: session.target, on: session.hostID, mode: .command)

        let shown = PiChat.outgoing([sent, waiting, answer, command], messages: [message(1, .user, "把断言也改了", delivery: sent.id)])

        #expect(shown.map(\.id) == [waiting.id])
    }

    /// 没送到的话在列表行与会话页是同一个数（会话列表查询带出的 `undelivered`）：列表那一行先是"没能送达"的出错状态，
    /// 看过以后不再整行出错，但只要那几句还没重发或移除，行上留一个小标记；会话页顶栏一直写"N 句没送到"。
    @Test func 没送到的话_看过以后行上仍留标记_与会话页同一个数() async throws {
        let app = TestApp()
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac-fail").update(sessionID: "relay", state: .settled, title: "relay")
        let target = SendTarget(kind: .piSession, name: "relay", ref: "relay")
        let lost = try await store.requestDelivery("改完再跑一遍", to: target, on: "mac-fail", mode: .send)
        _ = try await store.requestDelivery("还在路上的一句", to: target, on: "mac-wait", mode: .send)
        func item() async throws -> PiSessionListItem { try #require(try await store.piSessionPage(PiSessionQuery()).items.first) }
        #expect(try await item().undelivered(at: .always()) == 0)

        let executor = DeliveryExecutor(store: store, hostID: "mac-fail", onIssue: { _ in }) { _ in .failed("Pi 已经退出") }
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequest(lost.id)?.isOpen }) { $0 == false }
        await executor.stop()

        let failed = try await item()
        #expect(failed.undelivered(at: .always()) == 1 && PiChat.undeliveredNote(failed.undelivered(at: .always())) == "1 句没送到")
        #expect(try await SessionDigest.read(failed.id, sessionID: "relay", from: store).undelivered(at: .always()) == 1)

        app.services.settings.markSeen(failed.state, at: .now.addingTimeInterval(1))
        #expect(Workspace(services: app.services).shown(try await item()).undelivered == nil)
        #expect(try await item().undelivered(at: .always()) == 1)
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
