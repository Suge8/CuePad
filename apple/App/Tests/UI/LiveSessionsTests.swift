import CueStore
import Foundation
import Testing
@testable import CuePad

/// 此刻有事的会话整个 App 只读一份（`LiveSessions`）：底栏角标、侧栏、书架、前台提示、发送菜单、Mac 的会话摘要都从这里取。
@MainActor
struct LiveSessionsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var live: LiveSessions { app.services.liveSessions }

    private func refresh() async throws {
        live.apply(try await LiveSessions.Page.read(from: store))
    }

    @Test func 在线的与还有话发给它的已结束会话都在_在线的单取() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac")
        try await recorder.update(sessionID: "a", state: .thinking, title: "atlas")
        try await recorder.update(sessionID: "b", state: .settled, title: "billing")
        try await recorder.end(sessionID: "b")
        try await store.requestDelivery("再跑一遍", to: SendTarget(kind: .piSession, name: "billing", ref: "b"), on: "mac")
        try await recorder.update(sessionID: "c", state: .settled, title: "old")
        try await recorder.end(sessionID: "c")
        try await refresh()

        #expect(Set(live.items.map(\.state.sessionID)) == ["a", "b"])  // c 已结束、没有话在路上
        #expect(live.live.map(\.state.sessionID) == ["a"])
        #expect(live.items.first { $0.state.sessionID == "b" }?.delivery != nil)  // 唤醒中的已结束会话带着发给它的话
        #expect(live.total == 3)
    }

    @Test func 等你确认的个数随会话状态变_别的变化不触发() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac")
        try await recorder.update(sessionID: "a", state: .thinking, title: "atlas")
        let following = Task { try await live.follow(store) }
        defer { following.cancel() }
        var waiting = Observations { live.waiting }.makeAsyncIterator()
        #expect(await waiting.next() == 0)

        try await recorder.update(sessionID: "a", state: .tool, detail: "bash · pnpm test", title: "atlas")  // 不是等你确认
        try await recorder.update(sessionID: "a", state: .waitingForUser, title: "atlas")
        #expect(await waiting.next() == 1)
        try await recorder.update(sessionID: "a", state: .settled, title: "atlas")
        #expect(await waiting.next() == 0)
    }
}
