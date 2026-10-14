import CueStore
import CueSync
import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import CuePad

/// 发消息只有一条路（`Workspace.speak`），对 Cue 说与发给会话一样：按下发送输入框立刻空、只多一条记录（一个气泡），
/// 之后到哪了只看记录与时间（`Speech`）：发送中 → 已送达；Mac 报失败或过了时限没回执是没能送达，可重发（撤回旧的、写同样的新的，文字不丢）；
/// 写库失败时文字回到输入框。Cue 在不在睡觉也只看你最后一句的同一条规则。
@MainActor
struct SpeakTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var files: AttachmentFiles { app.services.store.files }

    /// Cue 住在 mac-cue（不是这台：发给它要经同步）。
    private func enableCue() async throws {
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-cue"
            profile.enabledAt = .now
        }
    }

    private func session(host: String = "mac-b") async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: "atlas", state: .settled, title: "atlas")
        return try #require(try await store.allPiSessionStates().first)
    }

    private func youSaid() async throws -> [CueMessage] {
        try await store.cueMessages().filter { $0.author == .known(.you) }
    }

    private func presence(at now: Date, reachable: Bool = true) async throws -> CuePresence {
        let moment = Speech.Moment(now: now, reachableSince: reachable ? .distantPast : nil)
        return CuePresence.derive(try await CueDigest.read(from: store, at: moment), at: moment)
    }

    /// 让这张表的写入失败（磁盘满、库坏了一类的写库失败）。
    private func breakWrites(to table: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(app.services.location.databaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TRIGGER broken BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, '磁盘满了'); END;"
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    // MARK: 对 Cue 说

    @Test func 对Cue说_按发送输入框立刻空_只多一条你的话并立即上传_交给它之后是已送达() async throws {
        try await enableCue()
        let workspace = Workspace(services: app.services)
        workspace.cue.draft = ComposerDraft(text: "看看发布")

        let writing = workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: files) }
        #expect(workspace.cue.draft.text.isEmpty)
        await writing?.value

        let said = try await youSaid()
        #expect(said.map(\.text) == ["看看发布"])
        let message = try #require(said.first)
        var uploads = app.sync.uploads.stream.makeAsyncIterator()
        #expect(await uploads.next() == message.id.uuidString.lowercased())
        #expect(Said.cue(message, host: "mac-cue").trip(at: .always(at: .now)) == .sending)
        #expect(try await presence(at: .now, reachable: true) == .sending)  // Cue 页头与气泡同一个"在路上"

        try await store.markCueMessagesDelivered([message.id])  // Cue 住的那台 Mac 交给了它
        let delivered = try #require(try await youSaid().first)
        #expect(Said.cue(delivered, host: "mac-cue").trip(at: .always(at: .now)) == .delivered)
    }

    /// 回执晚到但在时限内：一直是发送中，Cue 也是话在路上、不在睡觉；过了时限同步通着是 Mac 没有回应、Cue 在睡觉；
    /// 本机同步不通时写同步的原因、不说 Cue 在睡觉（照它写下的状态）；超时后回执来了照样是已送达，Cue 照它写下的在做事。
    @Test func 对Cue说_回执在时限内不报睡觉_超时才报_本机同步不通时不报() async throws {
        try await enableCue()
        let workspace = Workspace(services: app.services)
        workspace.cue.draft = ComposerDraft(text: "顺便看看登录回调那个超时")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: files) }?.value
        let message = try #require(try await youSaid().first)
        let said = Said.cue(message, host: "mac-cue")
        let inTime = message.createdAt.addingTimeInterval(Speech.receiptLimit - 1)
        let late = message.createdAt.addingTimeInterval(Speech.receiptLimit + 1)

        #expect(said.trip(at: .always(at: inTime)) == .sending)
        #expect(try await presence(at: inTime, reachable: true) == .sending)

        #expect(said.trip(at: .always(at: late)) == .failed(.noReply))
        #expect(try await presence(at: late, reachable: true) == .asleep)
        #expect(CuePresence.asleep.line(name: "Cue") == "Cue 在睡觉：它住的那台 Mac 好像没开")

        #expect(said.trip(at: Speech.Moment(now: late, reachableSince: nil)) == .failed(.offline))
        #expect(try await presence(at: late, reachable: false) == .idle)

        try await store.markCueMessagesDelivered([message.id])
        try await store.setCueState(.thinking)  // 值班的 Mac 交给它后写下它在想
        #expect(Said.cue(try #require(try await youSaid().first), host: "mac-cue").trip(at: .always(at: late)) == .delivered)
        #expect(try await presence(at: late, reachable: true) == .working(.thinking, detail: nil))
    }

    @Test func 对Cue说_没能送达后重发_撤回旧的写一条同样的_交出去的撤不回也不重发() async throws {
        try await enableCue()
        let workspace = Workspace(services: app.services)
        workspace.cue.draft = ComposerDraft(text: "README 的截图也交给你")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: files) }?.value
        let old = try #require(try await youSaid().first)

        workspace.resend(.cue(old, host: "mac-cue"), restoringInto: Bindable(workspace.cue).draft)
        let renewed = try await eventually(store, { try $0.cueMessages().filter { $0.author == .known(.you) } }) { $0.count == 1 && $0[0].id != old.id }
        #expect(renewed.map(\.text) == ["README 的截图也交给你"])
        #expect(workspace.cue.draft.text.isEmpty)

        // 这一句其实已经交给了 Cue（回执还没回到本机时点了重发）：撤不回，不重发，说明原因
        try await store.markCueMessagesDelivered([renewed[0].id])
        workspace.resend(.cue(renewed[0], host: "mac-cue"), restoringInto: Bindable(workspace.cue).draft)
        try await eventually("提示撤不回") { workspace.notice?.text == "Cue 已经收到这句了，撤不回" }
        #expect(try await youSaid().map(\.id) == [renewed[0].id])
    }

    @Test func 对Cue说_写库失败_文字回到输入框_期间新打的字接在后面() async throws {
        try await enableCue()
        let workspace = Workspace(services: app.services)
        try breakWrites(to: "cueMessages")
        workspace.cue.draft = ComposerDraft(text: "看看发布")

        let writing = workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: files) }
        #expect(workspace.cue.draft.text.isEmpty)
        workspace.cue.draft.text = "再补一句"
        await writing?.value

        #expect(workspace.cue.draft.text == "看看发布\n\n再补一句")
        #expect(workspace.notice?.isError == true)
        #expect(try await youSaid().isEmpty)
    }

    /// 图片存不进图片库（磁盘满、目录没权限）：什么都没发，两条去处都一样——草稿原样留着，只看到报错，写出后的那句"已交给"不出现。
    @Test func 图片存不进图片库_什么都没发_草稿留着_只看到报错() async throws {
        try await enableCue()
        let target = try await session()
        let workspace = Workspace(services: app.services)
        let attachments = app.services.location.databaseURL.deletingLastPathComponent().appending(path: "Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: attachments.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: attachments.path) }
        let photo = PickedImage(data: pngData())
        let reply = app.services.settings.replyDraftBinding(for: target.id)

        for (listener, box) in [(Listener.cue, Bindable(workspace.cue).draft), (.session(target, mode: .send), reply)] {
            box.wrappedValue = ComposerDraft(text: "参考这张", images: [photo])
            let writing = workspace.speak(to: listener, from: box, saying: "已交给") { try $0.stored(in: files) }
            #expect(writing == nil)
            #expect(box.wrappedValue.text == "参考这张" && box.wrappedValue.images.map(\.id) == [photo.id])
            #expect(workspace.notice?.isError == true && workspace.notice?.text != "已交给")
        }
        #expect(try await youSaid().isEmpty)
        #expect(try await store.deliveryRequests().isEmpty)
    }

    // MARK: 发给会话

    @Test func 发给会话_按发送输入框立刻空_只多一个气泡_Mac送达后是已送达() async throws {
        let target = try await session()
        let workspace = Workspace(services: app.services)
        let box = app.services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: "把断言也改了")

        let writing = workspace.speak(to: .session(target, mode: .send), from: box) { try $0.stored(in: files) }
        #expect(box.wrappedValue.text.isEmpty)
        await writing?.value

        let requests = try await store.deliveryRequests()
        #expect(requests.map(\.content) == ["把断言也改了"] && requests.first?.hostID == "mac-b")
        let request = try #require(requests.first)
        #expect(PiChat.outgoing(requests, messages: [], at: .always()).map(\.id) == [request.id])
        #expect(Said.request(request).trip(at: .always(at: .now)) == .sending)

        let executor = DeliveryExecutor(store: store, hostID: "mac-b", onIssue: { _ in }) { _ in .succeeded }
        try await executor.start()
        let done = try await eventually(store, { try $0.deliveryRequest(request.id) }) { $0?.isOpen == false }
        await executor.stop()
        #expect(Said.request(try #require(done)).trip(at: .always(at: .now)) == .delivered)
    }

    /// Mac 报的失败写它的原因；没被领取、过了时限是 Mac 没有回应（领取了在执行的不算超时）；重发撤回旧的、写同样内容与方式的新的。
    @Test func 发给会话_Mac报失败或超时没领取是没能送达_领取了不算超时_重发撤回旧的() async throws {
        let target = try await session()
        let workspace = Workspace(services: app.services)
        let box = app.services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: "改完再跑一遍")
        await workspace.speak(to: .session(target, mode: .send), from: box) { try $0.stored(in: files) }?.value
        let lost = try #require(try await store.deliveryRequests().first)

        let executor = DeliveryExecutor(store: store, hostID: "mac-b", onIssue: { _ in }) { _ in .failed("Pi 已经退出") }
        try await executor.start()
        let failed = try #require(try await eventually(store, { try $0.deliveryRequest(lost.id) }) { $0?.isOpen == false })
        await executor.stop()
        #expect(Said.request(failed).trip(at: .always(at: .now)) == .failed(.reported("Pi 已经退出")))

        workspace.resend(.request(failed), restoringInto: box)
        let retried = try await eventually(store, { try $0.deliveryRequests() }) { $0.count == 1 && $0[0].id != lost.id }
        #expect(retried[0].content == "改完再跑一遍" && retried[0].mode == .known(.send) && retried[0].isOpen)
        #expect(box.wrappedValue.text.isEmpty)

        // Mac 一直没领取：过了时限是 Mac 没有回应，本机同步不通时写同步的原因
        let late = retried[0].createdAt.addingTimeInterval(Speech.receiptLimit + 1)
        #expect(Said.request(retried[0]).trip(at: .always(at: late)) == .failed(.noReply))
        #expect(Said.request(retried[0]).trip(at: Speech.Moment(now: late, reachableSince: nil)) == .failed(.offline))
        // 领取了在执行（如正在唤醒已结束的会话）：还是发送中
        var claimed = retried[0]
        claimed.status = .known(.executing)
        #expect(Said.request(claimed).trip(at: .always(at: late)) == .sending)

        workspace.resend(.request(retried[0]), restoringInto: box)
        let again = try await eventually(store, { try $0.deliveryRequests() }) { $0.count == 1 && $0[0].id != retried[0].id }
        #expect(again[0].content == "改完再跑一遍")
    }

    @Test func 发给会话_写库失败_文字回到输入框_期间新打的字接在后面() async throws {
        let target = try await session()
        let workspace = Workspace(services: app.services)
        try breakWrites(to: "deliveryRequests")
        let box = app.services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: "把断言也改了")

        let writing = workspace.speak(to: .session(target, mode: .send), from: box) { try $0.stored(in: files) }
        #expect(box.wrappedValue.text.isEmpty)
        box.wrappedValue.text = "顺便跑一遍"
        await writing?.value

        #expect(box.wrappedValue.text == "把断言也改了\n\n顺便跑一遍")
        #expect(workspace.notice?.isError == true)
        #expect(try await store.deliveryRequests().isEmpty)
    }
}
