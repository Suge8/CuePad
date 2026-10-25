import CueStore
import CueTestSupport
import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import CuePad

/// 发消息只有一条路（`Workspace.speak`），对 Cue 说与发给会话一样：按下发送输入框立刻空、只多一条记录（一个气泡），
/// 之后到哪了只看记录与时间（`Speech`）：发送中 → 已送达；Mac 报失败或过了时限没发出是没能送达，可重发（撤回旧的、写同样的新的，文字不丢）；
/// 写库失败时文字回到输入框。Cue 在不在睡觉只看它那台 Mac 的在线记录，不看你的话送没送到。
@MainActor
struct SpeakTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var files: AttachmentFiles { app.services.store.files }

    /// Cue 运行在 mac-cue（不是这台：发给它要经同步），那台醒着（它的在线记录同步来了）。
    private func enableCue() async throws {
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-cue"
            profile.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
    }

    private func session(host: String = "mac-b") async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: "atlas", state: .settled, title: "atlas")
        return try #require(try await store.allPiSessionStates().first)
    }

    private func youSaid() async throws -> [CueMessage] {
        try await store.cueMessages().filter { $0.author == .known(.you) }
    }

    /// Cue 在不在由库在读的那一刻推出（`CueDigest`），界面只补本机同步通不通。
    private func presence(reachable: Bool = true) async throws -> CuePresence {
        CuePresence.derive(try await CueDigest.read(from: store), at: Speech.Moment(now: .now, reachableSince: reachable ? .distantPast : nil))
    }

    /// 把你这句话的写下时刻挪到 `ago` 秒前：时限从真实的此刻起算，不等一分钟。
    private func backdate(_ message: CueMessage, by ago: TimeInterval) throws {
        try RawDB(app.services.location.databaseURL).exec(
            "UPDATE cueMessages SET createdAt = \(Int((Date.now.timeIntervalSince1970 - ago) * 1000)) WHERE id = '\(message.id.uuidString.lowercased())'")
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
        #expect(try await presence() == .sending(.sending))  // Cue 页头与气泡同一个"在路上"

        try await store.markCueMessagesDelivered([message.id])  // Cue 运行的那台 Mac 交给了它
        let delivered = try #require(try await youSaid().first)
        #expect(Said.cue(delivered, host: "mac-cue").trip(at: .always(at: .now)) == .delivered)
    }

    /// 对 Cue 说的输入框也是随手记：长按发送"只记下"，或 Cue 没启用时按发送，这句不交给 Cue，记成默认项目里的一条灵感
    /// （不选项目；文字在前、图片按顺序在后），输入框立刻空，提示落点；Cue 那边不多一句你的话。
    @Test(arguments: [true, false])
    func 只记下或Cue没启用时发送_记成默认项目里的灵感_输入框立刻空_不对Cue说(cueEnabled: Bool) async throws {
        if cueEnabled { try await enableCue() }
        let workspace = Workspace(services: app.services)
        let photos = [PickedImage(data: pngData(shade: 0.1)), PickedImage(data: pngData(shade: 0.9))]
        workspace.cue.draft = ComposerDraft(text: "  周末读完第三章  ", images: photos)
        let box = Bindable(workspace.cue).draft

        let writing = cueEnabled ? workspace.note(from: box) : workspace.sayToCue(from: box)
        #expect(workspace.cue.draft.isEmpty(accepting: .images))
        await writing?.value

        let hashes = try photos.map { try files.store($0.data) }
        #expect(try await store.cards(in: Project.defaultID).map(\.body) == ["周末读完第三章\n\n![](cuepad://img/\(hashes[0]))\n![](cuepad://img/\(hashes[1]))"])
        #expect(workspace.notice?.text == "已记到 默认")
        #expect(try await youSaid().isEmpty)
    }

    /// 这里没有同步，话一直出不了这台：写下 `Speech.sendLimit` 之内是发送中，Cue 是话在路上；过了这句没能送达，
    /// 但那台 Mac 在线 Cue 就不算睡觉、仍在值班；那台 Mac 将睡眠标了离线 Cue 才在睡觉、不值班，本机同步不通时不说它在睡觉（照它写下的状态）；
    /// 没能送达后回执来了照样是已送达，Cue 照它写下的在做事。已发出后迟迟没回执见 `ReceiptTests`。
    @Test func 对Cue说_没发出只说这句没送到_在睡觉只看那台Mac在不在线() async throws {
        try await enableCue()
        let workspace = Workspace(services: app.services)
        workspace.cue.draft = ComposerDraft(text: "顺便看看登录回调那个超时")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: files) }?.value
        let message = try #require(try await youSaid().first)
        let said = Said.cue(message, host: "mac-cue")
        let inTime = message.createdAt.addingTimeInterval(Speech.sendLimit - 1)
        let late = message.createdAt.addingTimeInterval(Speech.sendLimit + 1)

        #expect(said.trip(at: .always(at: inTime)) == .sending)
        try backdate(message, by: Speech.sendLimit - 1)
        #expect(try await presence() == .sending(.sending))

        #expect(said.trip(at: .always(at: late)) == .failed(.unsent))
        try backdate(message, by: Speech.sendLimit + 1)
        #expect(try await presence() == .idle)
        #expect(try await store.cueDuty() != nil)

        try await store.recordMacPresence(host: "mac-cue") { false }  // 那台 Mac 将睡眠：标成离线，同步到这里
        #expect(try await presence() == .asleep)
        #expect(try await store.cueDuty() == nil)  // 值班与"在睡觉"同一条
        #expect(try await presence(reachable: false) == .idle)

        try await store.recordMacPresence(host: "mac-cue") { true }  // 醒来续上在线，收下你的话
        try await store.markCueMessagesDelivered([message.id])
        try await store.setCueState(.thinking)  // 值班的 Mac 交给它后写下它在想
        #expect(Said.cue(try #require(try await youSaid().first), host: "mac-cue").trip(at: .always(at: late)) == .delivered)
        #expect(try await presence() == .working(.thinking, detail: nil, step: nil))
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
        #expect(PiChat.outgoing(requests, messages: []).map(\.id) == [request.id])
        #expect(Said.request(request).trip(at: .always(at: .now)) == .sending)

        let executor = DeliveryExecutor(store: store, hostID: "mac-b", onIssue: { _ in }) { _ in .succeeded }
        try await executor.start()
        let done = try await eventually(store, { try $0.deliveryRequest(request.id) }) { $0?.isOpen == false }
        await executor.stop()
        #expect(Said.request(try #require(done)).trip(at: .always(at: .now)) == .delivered)
    }

    /// Mac 报的失败写它的原因；领取了在执行的过了时限也不算超时（没领取的超时见 `ReceiptTests`）；重发撤回旧的、写同样内容与方式的新的。
    @Test func 发给会话_Mac报失败是没能送达_领取了不算超时_重发撤回旧的() async throws {
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

        // 领取了在执行（如正在唤醒已结束的会话）：已发出，过了时限也不算没能送达
        let late = retried[0].createdAt.addingTimeInterval(Speech.receiptLimit + 1)
        var claimed = retried[0]
        claimed.status = .known(.executing)
        #expect(Said.request(claimed).trip(at: .always(at: late)) == .sent)

        workspace.resend(.request(retried[0]), restoringInto: box)
        let again = try await eventually(store, { try $0.deliveryRequests() }) { $0.count == 1 && $0[0].id != retried[0].id }
        #expect(again[0].content == "改完再跑一遍")
    }

    /// 写库失败（对 Cue 说、发给会话一样）：文字回到输入框，期间新打的字接在后面，报错，什么都没写下。
    @Test(arguments: [true, false])
    func 写库失败_文字回到输入框_期间新打的字接在后面(toCue: Bool) async throws {
        try await enableCue()
        let target = try await session()
        let workspace = Workspace(services: app.services)
        try breakWrites(to: toCue ? "cueMessages" : "deliveryRequests")
        let box = toCue ? Bindable(workspace.cue).draft : app.services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: "看看发布")

        let writing = workspace.speak(to: toCue ? .cue : .session(target, mode: .send), from: box) { try $0.stored(in: files) }
        #expect(box.wrappedValue.text.isEmpty)
        box.wrappedValue.text = "再补一句"
        await writing?.value

        #expect(box.wrappedValue.text == "看看发布\n\n再补一句")
        #expect(workspace.notice?.isError == true)
        #expect(try await youSaid().isEmpty)
        #expect(try await store.deliveryRequests().isEmpty)
    }
}
