import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话回复框（iOS 与 Mac 同一个）：主按钮一颗、按状态切换；排队的话在回复框上方一叠、不再是对话末尾的气泡；
/// 空回复框按 ↑ 调回你说过的上一句；会话可以标为未读。
@MainActor
struct ReplyBarTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

    private func session(_ state: PiWorkState, question: PiQuestion? = nil) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: "做一下", lastReply: "做完了", question: question, notify: nil, stateSince: at(100), busySince: nil,
            createdAt: at(0), modifiedAt: at(0))
    }

    // MARK: 主按钮

    /// 空着而 Agent 在跑一轮是停止；有字时点按（⌘↩）等它做完再说、长按（⌘⇧↩）马上说，没在跑时两种都是直接发送，斜杠命令不分；
    /// 等你确认时文字型问题是作答、选择型没有主按钮。
    @Test func 主按钮按状态切换() {
        #expect(MacDelivery.button(for: session(.tool), hasDraft: false) == .stop)
        #expect(MacDelivery.button(for: session(.thinking), hasDraft: false) == .stop)
        #expect(MacDelivery.button(for: session(.tool), hasDraft: true) == .send(tap: .followUp, hold: .steer))
        #expect(MacDelivery.button(for: session(.tool), hasDraft: true, command: true) == .send(tap: .command, hold: .command))
        for state in [PiWorkState.settled, .ended, .error, .delegating] {
            #expect(MacDelivery.button(for: session(state), hasDraft: true) == .send(tap: .send, hold: .send))
            #expect(MacDelivery.button(for: session(state), hasDraft: false) == .send(tap: .send, hold: .send))
        }
        let text = PiQuestion(promptID: "p", kind: .text, text: "新分支叫什么？")
        let pick = PiQuestion(promptID: "p", kind: .select, text: "覆盖吗？", options: ["是", "否"])
        #expect(MacDelivery.button(for: session(.waitingForUser, question: text), hasDraft: false) == .answer)
        #expect(MacDelivery.button(for: session(.waitingForUser, question: pick), hasDraft: true) == nil)
    }

    // MARK: 排队的话

    private func message(_ seq: Int64, _ text: String, delivery: UUID?) -> PiChatMessage {
        PiChatMessage(sessionID: "s", entryID: "e\(seq)", seq: seq, role: .user, text: text, at: at(Double(seq)), deliveryID: delivery)
    }

    /// 在跑时"等它做完再说"发出、还没进对话的话在回复框上方一叠，不再同时是对话末尾的气泡；
    /// 没能送达的仍是气泡（在对话里重发或移除），进了对话的两处都没有。
    @Test func 排队的话只在回复框上方_不再是末尾的气泡() async throws {
        let app = TestApp()
        try await PiStateRecorder(store: app.services.store, hostID: "mac").update(sessionID: "s", state: .tool, title: "s")
        let live = try #require(try await app.services.store.piSessionPage(.live).items.first?.state)
        let queued = try await app.services.requestMacDelivery("改完再看看超时", to: live, mode: .followUp)
        let arrived = try await app.services.requestMacDelivery("顺便跑一遍", to: live, mode: .followUp)
        let now = try await app.services.requestMacDelivery("先停下这个", to: live, mode: .steer)
        let messages = [message(1, "顺便跑一遍", delivery: arrived.id)]

        #expect(PiChat.queued([queued, arrived, now], messages: messages).map(\.id) == [queued.id])
        #expect(PiChat.outgoing([queued, arrived, now], messages: messages).map(\.id) == [now.id])
    }

    /// 撤回与改为马上说只对还没被 Mac 领取的（Pi 扩展收不回已交给 Pi 的话）。
    @Test func 还没被Mac领取的可撤回或改为马上说_领取后不行() async throws {
        let app = TestApp()
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s", state: .tool, title: "s")
        let live = try #require(try await store.piSessionPage(.live).items.first?.state)
        let first = try await app.services.requestMacDelivery("改完再看看超时", to: live, mode: .followUp)
        let second = try await app.services.requestMacDelivery("顺便跑一遍", to: live, mode: .followUp)
        #expect(first.isWithdrawable && second.isWithdrawable)

        #expect(try await store.promoteDelivery(first.id))
        #expect(try await store.deliveryRequest(first.id)?.mode == .known(.steer))
        #expect(try await store.withdrawDelivery(second.id))
        #expect(try await store.deliveryRequest(second.id) == nil)

        let executor = DeliveryExecutor(store: store, hostID: "mac", onIssue: { _ in }) { _ in .succeeded }
        let third = try await app.services.requestMacDelivery("再加一句", to: live, mode: .followUp)
        try await executor.start()
        for try await current in store.observe({ try $0.deliveryRequest(third.id) }) where current?.isOpen == false { break }
        await executor.stop()
        let handed = try #require(try await store.deliveryRequest(third.id))
        #expect(!handed.isWithdrawable)
        #expect(try await !store.withdrawDelivery(third.id))
        #expect(try await !store.promoteDelivery(third.id))
        #expect(try await store.deliveryRequest(third.id)?.mode == .known(.followUp))
    }

    // MARK: 调回上一句

    @Test func 调回的是对话里你最近说的一句() {
        let messages = [
            message(1, "跑一下测试", delivery: nil),
            PiChatMessage(sessionID: "s", entryID: "e2", seq: 2, role: .pi, text: "好了", at: at(2)),
            message(3, "把断言也改了", delivery: nil),
            PiChatMessage(sessionID: "s", entryID: "e4", seq: 4, role: .pi, text: "改好了", at: at(4)),
        ]
        #expect(PiChat.lastSaid(messages) == "把断言也改了")
        #expect(PiChat.lastSaid([]) == nil)
    }

    // MARK: 标为未读

    @Test func 看过的会话可以标为未读_规则启用前停下的也行() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "unread-\(UUID())")!, launchArguments: [:])
        let fresh = PiSessionState(
            id: UUID(), sessionID: "new", hostID: "mac", title: "new", projectID: nil, state: .known(.settled), detail: nil, folder: nil,
            lastPrompt: "做一下", lastReply: "做完了", question: nil, notify: nil, stateSince: .now.addingTimeInterval(60), busySince: nil,
            createdAt: .now, modifiedAt: .now)
        settings.markSeen(fresh, at: .now.addingTimeInterval(120))
        #expect(!settings.isUnread(fresh) && settings.canMarkUnread(fresh))

        settings.markUnread(fresh)
        #expect(settings.isUnread(fresh) && !settings.canMarkUnread(fresh))

        let old = session(.settled)  // 停在很久以前，早于规则启用
        #expect(!settings.isUnread(old) && settings.canMarkUnread(old))
        settings.markUnread(old)
        #expect(settings.isUnread(old))

        #expect(!settings.canMarkUnread(session(.tool)))  // 在跑的不是"做完了"
    }
}
