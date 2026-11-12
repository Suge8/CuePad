#if os(macOS)
import CloudKit
import CueStore
@testable import CueSync
import Foundation
import Testing
@testable import CuePad

@testable import CueBridge

extension MacSyncTests {
    @Test func 手机经同步切换Mac在线会话的加速_结果与状态回到手机() async throws {
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)])
        let mac = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, host: "phone")
        let changes = mac.bridge.changes()
        try mac.bridge.start()
        _ = try await mac.runtimeRecorder(on: TestApp.hostID)
        let recording = Task { try await mac.services.consumeSessionChanges(changes) }
        for side in [mac, phone] { side.services.startSync() }
        defer {
            recording.cancel()
            mac.bridge.stop()
            for side in [mac, phone] { side.services.cancelBackgroundWork() }
        }
        try await mac.services.executor.start()
        let ext = try await mac.host.connect("fast", cwd: mac.directory.path)
        defer { ext.close(bye: "quit") }
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "config", let fast = command["fast"] as? Bool {
                ext?.sendInfo(["fast": fast])
            }
            return ["ok": true]
        }
        let stateID = SessionState.recordID(sessionID: "fast")
        _ = try await eventually(mac.services.store, { try $0.allSessionStates().first }, until: { $0?.sessionID == "fast" })
        await mac.services.upload(stateID)
        await phone.services.syncNow()
        let session = try #require(try await eventually(phone.services.store, { try $0.allSessionStates().first }, until: { $0?.sessionID == "fast" }))

        let request = try await phone.services.configure(SessionConfig(fast: true), for: session)
        await phone.services.upload(request.id)
        await mac.services.syncNow()
        let result = try #require(try await eventually(mac.services.store, { try $0.deliveryRequest(request.id) }, until: { $0?.isOpen == false }))
        #expect(result.status == .known(.succeeded))
        try #require(ext.commands.last?.json["fast"] as? Bool == true)
        _ = try await eventually(mac.services.store, { try $0.allSessionStates().first?.fast }, until: { $0 == true })
        await mac.services.upload(stateID, request.id)
        await phone.services.syncNow()
        let received = try #require(try await eventually(phone.services.store, { try $0.deliveryRequest(request.id) }, until: { $0?.isOpen == false }))
        #expect(received.status == .known(.succeeded))
        #expect(try await phone.services.store.allSessionStates().first?.fast == true)
    }

    func launched(_ launch: LaunchRequest, title: String = "app", card: UUID? = nil) async throws -> DeliveryRequest {
        try await services.executor.start()
        let request = try await services.store.requestLaunch(launch, title: title, on: TestApp.hostID, card: card)
        return try await awaitFinished(request.id)
    }

    func folder(_ name: String) throws -> URL {
        let url = rig.directory.appending(path: "work/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func indexed(_ id: String, cwd: URL) async throws -> IndexedSession {
        let session = IndexedSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd.path, title: "修好登录", lastActivityAt: .now)
        try await services.store.upsertSession(session, host: TestApp.hostID)
        return session
    }

    @Test func 给已结束的会话改名_后台恢复后改_不写发送记录() async throws {
        let app = try folder("app")
        let indexed = try await indexed("s1", cwd: app)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestConfig(
            SessionConfig(name: "登录重试"), to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.resume(sessionFile: indexed.path, directory: app.path)])
        #expect(rig.host.extensions["s1"]?.commands.last?.json["name"] as? String == "登录重试")
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    @Test func 新会话_以步骤命名_开场的话带原图与文件路径_没有开场的话不发() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let task = try await services.store.createTask("上线", in: project.id)
        let step = try await services.store.createTask("备份数据库\n先把库备份一份", under: task.id)

        #expect(try await launched(LaunchRequest(project: project.id, prompt: step.body, token: "tok-6"), card: step.id).status == .known(.succeeded))
        #expect(rig.host.extensions["new-tok-6"]?.received == ["send"])
        guard case .open(_, _, let name, _, _) = try #require(rig.host.calls.first) else {
            Issue.record("没有开新会话")
            return
        }
        #expect(name == "备份数据库")

        let png = pngData()
        let hash = try services.store.files.store(png)
        let shown = try await launched(LaunchRequest(project: project.id, prompt: "看这张设计稿\n\n![](cuepad://file/\(hash))", token: "tok-5"), title: "App")
        #expect(rig.host.extensions["new-tok-5"]?.messages == [
            SessionMessage(text: "看这张设计稿", images: [MessageImage(mimeType: "image/png", data: png)], deliveryID: shown.id.uuidString)
        ])

        // 文件在原处换成一行"附件：文件名（路径）"，路径是附件目录里本机那份
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-方案.pdf")
        try Data("%PDF-1.4 方案".utf8).write(to: source)
        let pdf = try services.store.files.store(fileAt: source)
        let withFile = try await launched(LaunchRequest(project: project.id, prompt: "照这份方案做\n\n[方案.pdf](cuepad://file/\(pdf))", token: "tok-7"), title: "App")
        let path = try #require(services.store.files.fileURL(for: pdf)).path(percentEncoded: false)
        #expect(path.hasPrefix(services.location.caches.path(percentEncoded: false)))
        #expect(rig.host.extensions["new-tok-7"]?.messages == [SessionMessage(text: "照这份方案做\n\n附件：方案.pdf（\(path)）", deliveryID: withFile.id.uuidString)])

        #expect(try await launched(LaunchRequest(project: project.id, prompt: nil, token: "tok-2")).status == .known(.succeeded))
        #expect(rig.host.extensions["new-tok-2"]?.commands.isEmpty == true)
    }

    @Test
    func Cue开的新会话_请求清理之后开场白仍标着Cue() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let store = services.store
        try await services.executor.start()
        let request = try await store.requestLaunch(
            LaunchRequest(project: project.id, prompt: "看看测试为什么挂", token: "tok-cue"), title: "App", on: TestApp.hostID, cue: true)
        #expect(try await awaitFinished(request.id).status == .known(.succeeded))
        let ext = try #require(rig.host.extensions["new-tok-cue"])
        let received = try #require(ext.messages.first)
        let delivery = try #require(received.deliveryID.flatMap(UUID.init(uuidString:)))
        let said = ChatMessage(sessionID: ext.sessionID, entryID: "u0", seq: 0, role: .user, text: received.text, at: .now, deliveryID: delivery)
        try await store.writeTranscript(SessionTranscript(sessionID: ext.sessionID, messages: [said], recap: Recap(lastPrompt: said.text)))
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.succeeded))
        try await store.deleteDelivery(request.id)

        let derived = ChatDerived()
        derived.refresh(try await SessionDigest.read(SessionState.recordID(sessionID: ext.sessionID), sessionID: ext.sessionID, from: store), at: .always())
        #expect(try #require(derived.items.first).fromCue)
    }

    @Test(arguments: [true, false], [true, false])
    func 会话重载扩展接回_这期间做完一轮的才叫醒Cue(running: Bool, upgrading: Bool) async throws {
        let changes = rig.bridge.changes()
        try rig.bridge.start()
        let services: AppServices = services, store = services.store
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-sync-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let turn = Date.now.addingTimeInterval(-30 * 60)
        // Cue 开的这一轮：他开的停下不报给 Cue（`leaveHisStops`）
        let delivery = UUID()
        try await store.recordSend("发版", to: SendTarget(kind: .piSession, name: "发版", ref: "s1"), delivery: delivery, origin: .known(.cue))
        let said = ChatMessage(sessionID: "s1", entryID: "u1", seq: 1, role: .user, text: "发版", at: turn, deliveryID: delivery)
        try await services.stateRecorder.update(
            sessionID: "s1", state: .thinking, title: "发版", directory: "/work/app", times: SessionTimes(stateSince: turn, busySince: turn), turnStartedAt: turn)
        if !running {
            try await store.writeTranscript(SessionTranscript(
                sessionID: "s1", messages: [said], recap: Recap(lastPrompt: "发版", lastReply: "发好了", answeredAt: turn.addingTimeInterval(60))))
            try await services.stateRecorder.update(sessionID: "s1", state: .settled, times: SessionTimes(stateSince: turn.addingTimeInterval(60), busySince: nil))
        }
        try services.reconcileLaunch()  // 更新后的 App 启动对账
        let mark = try await store.lastWrite()
        let consuming = Task { try await services.consumeSessionChanges(changes) }
        defer { await consuming.stop() }

        let old = try await rig.host.connect(
            "s1", cwd: "/work/app", busy: running, extensionVersion: upgrading ? PiWire.oldestExtension - 1 : PiExtensionBundle.version, sessionFile: file.path)
        if running {
            try await store.writeTranscript(SessionTranscript(
                sessionID: "s1", messages: [said], recap: Recap(lastPrompt: "发版", lastReply: "发好了", answeredAt: .now)))
        }
        old.close(bye: "reload")
        try await rig.host.connect("s1", cwd: "/work/app", sessionFile: file.path)

        // 接回的那一次写入落了盘（记录的状态与起点跟上桥上的）才看 Cue 的变化，不然歇着的那一例还没写就判过了
        try await eventually("桥上以新扩展接回") { services.bridge.session(sessionID: "s1").map { $0.state == .settled && !$0.upgrading } == true }
        let live = try #require(services.bridge.session(sessionID: "s1"))
        let stored = try await eventually(store, { try $0.allSessionStates().first }, until: {
            $0?.state == .known(.settled) && abs(($0?.stateSince ?? .distantPast).timeIntervalSince(live.stateSince)) < 0.001
        })
        #expect(try await store.macOnline(TestApp.hostID))
        #expect(stored?.runtimeState == .known(.settled))
        let woke = try await store.cueChanges(after: CueMarks(mark))
        #expect(woke.map { "\($0.kind)\($0.interrupted ? "（被打断）" : "") \($0.session?.sessionID ?? "")" } == (running ? ["settled s1"] : []))
    }

    @Test(arguments: [false, true])
    func 进程没了的会话仍认它报过的斜杠命令(ended: Bool) async throws {
        var live = session("s1", state: .settled, spoke: true)
        live.commands = [SlashCommand(name: "default", summary: "回默认模式", source: .known(.builtin))]
        try await services.consumeSessionChanges(changes([.appeared(live), .ended(live, reason: .disconnected)]))
        if ended { try await StateRecorder(store: services.store, hostID: TestApp.hostID).end(sessionID: "s1") }

        let stored = try #require(try await services.store.allSessionStates().first)
        #expect(stored.state == .known(ended ? .ended : .settled))
        let catalogID = try #require(stored.catalogID)
        let catalog = try await services.store.agentCatalog(catalogID)
        #expect(catalog?.models.isEmpty ?? true)  // 可选模型不留
        #expect(Slash.line(of: ComposerDraft(text: "/default"), in: stored.usableCommands(in: catalog), for: stored) == "/default")
    }
}
#endif
