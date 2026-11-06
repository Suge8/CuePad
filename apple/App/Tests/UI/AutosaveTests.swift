import CueStore
import Synchronization
import Testing
@testable import CuePad

/// 自动保存：编辑器里停手一小会儿，正文就写进库，不用离开页面；写入慢或写不成时离开、交给 Agent，字也不丢。
struct AutosaveTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    /// 一次写入的闸门：`save` 开始后停在这里，放行才写。
    private final class Gate: Sendable {
        private let opened = AsyncStream<Void>.makeStream()
        private let started = AsyncStream<Void>.makeStream()
        func started() async { for await _ in started.stream { break } }
        func wait() async {
            started.continuation.yield()
            for await _ in opened.stream { break }
        }
        func open() { opened.continuation.yield() }
    }

    @Test func 编辑正文停手后写进库() async throws {
        let card = try await store.createCard(body: "续费域名")
        let editing = CardEditing(card, workspace: Workspace(services: app.services))

        editing.changed("续费域名\n顺便把证书也续了")

        _ = try await eventually(store, { try $0.card(card.id)?.body }) { $0 == "续费域名\n顺便把证书也续了" }
        withExtendedLifetime(editing) {}
    }

    /// 新记一条灵感先建一条空的再编辑：停手触发的写入还在路上时离开，等它落库，这条不能当成空白删掉。
    @Test func 写入在途时离开_等落库_新灵感的字不丢() async throws {
        let workspace = Workspace(services: app.services)
        let card = try await store.createCard(body: "")
        let gate = Gate(), id = card.id, store = store
        let autosave = Autosave(save: { text in
            await gate.wait()
            try await store.updateCard(id) { $0.body = text }
        }, onError: { _ in })

        autosave.changed("刚打的字")
        await gate.started()
        workspace.leaveEditing(id, flush: autosave)
        await quietPeriod(.milliseconds(200))
        #expect(try await store.card(id) != nil, "写入还没落库，离开不能先把它当空白删掉")
        gate.open()

        _ = try await eventually(store, { try $0.card(id)?.body }) { $0 == "刚打的字" }
        await quietPeriod(.milliseconds(200))
        #expect(try await store.card(id)?.body == "刚打的字")
    }

    /// 交给 Agent 前的 flush 要等在途写入落库，读到的才是最新的字。
    @Test func flush等在途写入落库() async throws {
        let gate = Gate(), written = Mutex(false)
        let autosave = Autosave(save: { _ in
            await gate.wait()
            written.withLock { $0 = true }
        }, onError: { _ in })

        autosave.changed("新正文")
        await gate.started()
        let flushing = Task { try await autosave.flush() }
        await quietPeriod(.milliseconds(100))
        gate.open()
        try await flushing.value
        #expect(written.withLock { $0 }, "flush 返回时写入已完成")
    }

    /// 停手触发的写入失败了：字放回待写，离开时再写一次；这次再失败就报错、不删。
    @Test func 写失败后离开再试一次_仍失败就报错不删() async throws {
        struct Boom: Error {}
        let workspace = Workspace(services: app.services)
        let card = try await store.createCard(body: "")
        let id = card.id, store = store
        let attempts = Mutex(0), failures = Mutex(0)
        let autosave = Autosave(save: { text in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt != 2 { throw Boom() }
            try await store.updateCard(id) { $0.body = text }
        }, onError: { _ in failures.withLock { $0 += 1 } })

        autosave.changed("刚打的字")
        try await eventually("停手触发的写入失败了") { failures.withLock { $0 } == 1 }
        workspace.leaveEditing(id, flush: autosave)
        _ = try await eventually(store, { try $0.card(id)?.body }) { $0 == "刚打的字" }

        // 再失败：不删，字还在待写里
        let blank = try await store.createCard(body: "")
        let failing = Autosave(save: { _ in throw Boom() }, onError: { _ in })
        failing.changed("写不进去")
        workspace.leaveEditing(blank.id, flush: failing)
        try await eventually("报了错") { workspace.notice?.isError == true }
        #expect(try await store.card(blank.id) != nil)

        // 页面已走：字由 Workspace 带着，再打开这条时接回来并写进库
        try await eventually("字被带着") { workspace.unsavedBodies[blank.id]?.text == "写不进去" }
        let reopened = CardEditing(try #require(try await store.card(blank.id)), workspace: workspace)
        #expect(reopened.initialText == "写不进去")
        _ = try await eventually(store, { try $0.card(blank.id)?.body }) { $0 == "写不进去" }
        try await eventually("写成了就不再带着") { workspace.unsavedBodies[blank.id] == nil }
        withExtendedLifetime(reopened) {}
    }

    /// 离开时写失败的字：再打开前这条只是别的属性变了（置顶）照常接回；正文在别处被改了就接在新正文后面，两份都不丢。
    @Test func 写失败的字再打开_正文没变接回_正文被别处改了接在后面() async throws {
        struct Boom: Error {}
        let workspace = Workspace(services: app.services)
        let store = store
        func fail(_ card: Card, typing text: String) async throws {
            let failing = Autosave(save: { _ in throw Boom() }, onError: { _ in })
            failing.changed(text)
            workspace.leaveEditing(card.id, flush: failing)
            try await eventually("字被带着") { workspace.unsavedBodies[card.id]?.text == text }
        }
        let pinned = try await store.createCard(body: "原文")
        try await fail(pinned, typing: "原文加我的字")
        try await store.updateCard(pinned.id) { $0.isPinned = true }
        let first = CardEditing(try #require(try await store.card(pinned.id)), workspace: workspace)
        #expect(first.initialText == "原文加我的字")

        let edited = try await store.createCard(body: "原文")
        try await fail(edited, typing: "原文加我的字")
        try await store.updateCard(edited.id) { $0.body = "别处改的" }
        let second = CardEditing(try #require(try await store.card(edited.id)), workspace: workspace)
        #expect(second.initialText == "别处改的\n\n原文加我的字")
        withExtendedLifetime([first, second]) {}
    }
}
