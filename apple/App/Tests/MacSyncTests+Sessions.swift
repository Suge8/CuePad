#if os(macOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

@testable import CuePi

extension MacSyncTests {
    func launched(_ launch: PiLaunch, title: String = "app", card: UUID? = nil) async throws -> DeliveryRequest {
        try await services.executor.start()
        let request = try await services.store.requestLaunch(launch, title: title, on: TestApp.hostID, card: card)
        return try await awaitFinished(request.id)
    }

    /// 测试目录里的一个真实文件夹（执行器启动前检查目录存在）。
    func folder(_ name: String) throws -> URL {
        let url = rig.directory.appending(path: "work/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func indexed(_ id: String, cwd: URL) async throws -> IndexedSession {
        let session = IndexedSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd.path, title: "修好登录", lastActivityAt: .now)
        try await services.store.upsertPiSession(session, host: TestApp.hostID)
        return session
    }

    /// 改名是会话设置（配置请求带名字）：发给已结束的会话时与发消息同一条路，先在后台恢复它再交给扩展改名；不写发送记录。
    @Test func 给已结束的会话改名_后台恢复后改_不写发送记录() async throws {
        let app = try folder("app")
        let indexed = try await indexed("s1", cwd: app)
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestConfig(
            PiConfig(name: "登录重试"), to: SendTarget(kind: .piSession, name: "修好登录", ref: "s1"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls == [.resume(sessionFile: indexed.path, directory: app.path)])
        #expect(rig.host.extensions["s1"]?.commands.last?.json["name"] as? String == "登录重试")
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// 新会话的会话名与模型、思考强度一样是 Pi 的启动参数：从步骤开的叫步骤名，开出来就叫它，再送开场的话（会话名不会先成了第一句话）；
    /// 开场的话里带图片的，原图随第一条消息送达，不把存储格式的引用当文字发出去；文件写成本机的路径；没有开场的话就什么都不发。
    @Test func 新会话_以步骤命名_开场的话带原图与文件路径_没有开场的话不发() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let task = try await services.store.createTask("上线", in: project.id)
        let step = try await services.store.createTask("备份数据库\n先把库备份一份", under: task.id)

        #expect(try await launched(PiLaunch(project: project.id, prompt: step.body, token: "tok-6"), card: step.id).status == .known(.succeeded))
        #expect(rig.host.extensions["new-tok-6"]?.received == ["send"])
        guard case .open(_, _, let name, _, _) = try #require(rig.host.calls.first) else {
            Issue.record("没有开新会话")
            return
        }
        #expect(name == "备份数据库")

        let png = pngData()
        let hash = try services.store.files.store(png)
        let shown = try await launched(PiLaunch(project: project.id, prompt: "看这张设计稿\n\n![](cuepad://file/\(hash))", token: "tok-5"), title: "App")
        #expect(rig.host.extensions["new-tok-5"]?.messages == [
            PiMessage(text: "看这张设计稿", images: [PiImage(mimeType: "image/png", data: png)], deliveryID: shown.id.uuidString)
        ])

        // 文件在原处换成一行"附件：文件名（路径）"，路径是附件目录里本机那份
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-方案.pdf")
        try Data("%PDF-1.4 方案".utf8).write(to: source)
        let pdf = try services.store.files.store(fileAt: source)
        let withFile = try await launched(PiLaunch(project: project.id, prompt: "照这份方案做\n\n[方案.pdf](cuepad://file/\(pdf))", token: "tok-7"), title: "App")
        let path = try #require(services.store.files.fileURL(for: pdf)).path(percentEncoded: false)
        #expect(path.hasPrefix(services.location.caches.path(percentEncoded: false)))
        #expect(rig.host.extensions["new-tok-7"]?.messages == [PiMessage(text: "照这份方案做\n\n附件：方案.pdf（\(path)）", deliveryID: withFile.id.uuidString)])

        #expect(try await launched(PiLaunch(project: project.id, prompt: nil, token: "tok-2")).status == .known(.succeeded))
        #expect(rig.host.extensions["new-tok-2"]?.commands.isEmpty == true)
    }

    /// Cue 开的新会话：开场白同所有送进会话的话一样记发送记录（带请求 id 与来源），请求清理之后会话页里它仍标着 Cue。
    @Test
    func Cue开的新会话_请求清理之后开场白仍标着Cue() async throws {
        let directory = try folder("proj")
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory(directory.path, for: project.id)
        defer { services.cancelBackgroundWork() }
        let store = services.store
        try await services.executor.start()
        let request = try await store.requestLaunch(
            PiLaunch(project: project.id, prompt: "看看测试为什么挂", token: "tok-cue"), title: "App", on: TestApp.hostID, cue: true)
        #expect(try await awaitFinished(request.id).status == .known(.succeeded))
        let ext = try #require(rig.host.extensions["new-tok-cue"])
        try await store.deleteDelivery(request.id)
        let said = PiChatMessage(sessionID: ext.sessionID, entryID: "u0", seq: 0, role: .user, text: "看看测试为什么挂", at: .now, deliveryID: request.id)
        try await store.writePiTranscript(PiTranscript(sessionID: ext.sessionID, messages: [said], recap: PiRecap(lastPrompt: said.text)))

        let derived = ChatDerived()
        derived.refresh(try await SessionDigest.read(PiSessionState.recordID(sessionID: ext.sessionID), sessionID: ext.sessionID, from: store))
        #expect(try #require(derived.items.first).fromCue)
    }

    /// App 更新后，开着的会话歇下后自己重新载入扩展、接回（新载入的扩展没见过这一轮：开始报空、起点是此刻）。
    /// 扩展旧到 CuePad 读不懂的（`upgrading`）这期间读不到状态，记录停在更新前的样子；读得懂的照常读着。更新前在跑、重载前做完了这一轮的，
    /// 接回时照常算一次歇下，Cue 被叫醒（他不在场：那句话说在半小时前）；更新前就歇着的，接回不是新的歇下，不叫醒。
    @Test(arguments: [true, false], [true, false])
    func 会话重载扩展接回_这期间做完一轮的才叫醒Cue(running: Bool, upgrading: Bool) async throws {
        let changes = rig.pi.changes()
        try rig.pi.start()
        let services: AppServices = services, store = services.store
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-sync-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let turn = Date.now.addingTimeInterval(-30 * 60)
        let said = PiChatMessage(sessionID: "s1", entryID: "u1", seq: 1, role: .user, text: "发版", at: turn)
        try await services.piStateRecorder.update(
            sessionID: "s1", state: .thinking, title: "发版", directory: "/work/app", times: PiTimes(stateSince: turn, busySince: turn), turnStartedAt: turn)
        if !running {
            try await store.writePiTranscript(PiTranscript(
                sessionID: "s1", messages: [said], recap: PiRecap(lastPrompt: "发版", lastReply: "发好了", answeredAt: turn.addingTimeInterval(60))))
            try await services.piStateRecorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: turn.addingTimeInterval(60), busySince: nil))
        }
        try await services.resetPiState()  // 更新后的 App 启动对账
        let mark = try await store.lastWrite()
        let consuming = Task { try await services.consumePiChanges(changes) }
        defer { consuming.cancel() }

        let old = try await rig.host.connect(
            "s1", cwd: "/work/app", busy: running, extensionVersion: upgrading ? PiWire.oldestExtension - 1 : PiExtensionBundle.version, sessionFile: file.path)
        if running {
            try await store.writePiTranscript(PiTranscript(
                sessionID: "s1", messages: [said], recap: PiRecap(lastPrompt: "发版", lastReply: "发好了", answeredAt: .now)))
        }
        old.close(bye: "reload")
        try await rig.host.connect("s1", cwd: "/work/app", sessionFile: file.path)

        // 接回的那一次写入落了盘（记录的状态与起点跟上桥上的）才看 Cue 的变化，不然歇着的那一例还没写就判过了
        try await eventually("桥上以新扩展接回") { services.pi.session(sessionID: "s1").map { $0.state == .settled && !$0.upgrading } == true }
        let live = try #require(services.pi.session(sessionID: "s1"))
        _ = try await eventually(store, { try $0.allPiSessionStates().first }, until: {
            $0?.state == .known(.settled) && abs(($0?.stateSince ?? .distantPast).timeIntervalSince(live.stateSince)) < 0.001
        })
        let woke = try await store.cueChanges(after: CueMarks(mark))
        #expect(woke.due.map { "\($0.kind)\($0.interrupted ? "（被打断）" : "") \($0.session?.sessionID ?? "")" } == (running ? ["settled s1"] : []))
    }

    /// 后台托管的会话进程没了（App 退出、闲置退出）记录仍歇着、发话会唤醒它：它报过的斜杠命令留着，
    /// 回复框里打完整的 "/default" 照样是命令（后台唤醒后执行），不当普通的话发给模型。会话做完的也一样。
    @Test(arguments: [true, false])
    func 进程没了的会话仍认它报过的斜杠命令(hosted: Bool) async throws {
        var live = session("s1", state: .settled, spoke: true)
        live.hosted = hosted
        live.commands = [PiSlashCommand(name: "default", summary: "回默认模式", source: .known(.builtin))]
        try await services.consumePiChanges(changes([.appeared(live), .ended(live, reason: .disconnected)]))
        if !hosted { try await PiStateRecorder(store: services.store, hostID: TestApp.hostID).end(sessionID: "s1") }

        let stored = try #require(try await services.store.allPiSessionStates().first)
        #expect(stored.state == .known(hosted ? .settled : .ended))
        let catalogID = try #require(stored.catalogID)
        let catalog = try await services.store.agentCatalog(catalogID)
        #expect(catalog?.models.isEmpty ?? true)  // 可选模型不留
        #expect(PiSlash.line(of: ComposerDraft(text: "/default"), in: stored.usableCommands(in: catalog)) == "/default")
    }

    /// 后台托管着时，用户在自己的终端里打开了同一个会话：同步记录跟着用户那个进程（不再标"后台托管"），
    /// 后台进程随后退出也不把记录标为已结束——始终只有一条。
    @Test func 同一会话换到用户的终端里_记录跟着新进程_后台进程退出不结束记录() async throws {
        var hosted = session("s1", pid: 100)
        hosted.hosted = true
        var mine = session("s1", pid: 200)
        mine.state = .tool
        try await services.consumePiChanges(changes([
            .appeared(hosted), .appeared(mine), .stateChanged(hosted, from: .thinking), .ended(hosted, reason: .closed(reason: "quit")),
        ]))

        let records = try await services.store.allPiSessionStates()
        #expect(records.count == 1)
        #expect(records.first?.hosted == false && records.first?.state == .known(.tool))
    }
}
#endif
