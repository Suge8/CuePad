#if os(macOS)
import CueStore
import CueSync
import Foundation
import Testing
import AppKit
@testable import CuePad
@testable import CuePi

extension MacSyncTests {
    // MARK: 手机发来的投送请求

    /// 等请求有结果；10 秒没有就失败并说明（观察流不会自己结束，没有上限会无声挂住整个测试宿主）。
    func awaitFinished(_ id: UUID) async throws -> DeliveryRequest {
        let store = services.store
        return try await withThrowingTaskGroup(of: DeliveryRequest.self) { group in
            group.addTask {
                for try await request in store.observe({ try $0.deliveryRequest(id) }) {
                    if let request, request.status == .known(.succeeded) || request.status == .known(.failed) { return request }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw TimedOut(what: "投送请求 \(id) 没有在 60 秒内出结果")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    struct TimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    /// 手机对在线会话的斜杠命令、作答、改配置、结束、停止：各走桥的命令通道（命令由 Pi 展开执行，不当文字发出），按成功写回，
    /// 不恢复会话、不写发送记录（发送记录只记内容的投送）。
    @Test func 手机的控制请求交给桥按各自的通道执行_不写发送记录() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let store = services.store, host = TestApp.hostID
        func target(_ ref: String) -> SendTarget { SendTarget(kind: .piSession, name: "app", ref: ref) }
        let cases: [(ref: String, received: String, request: () async throws -> DeliveryRequest, sent: ([String: Any]) -> Bool)] = [
            ("command", "command", { try await store.requestDelivery("/greet world", to: target("command"), on: host, mode: .command) },
             { $0["text"] as? String == "/greet world" }),
            ("answer", "answer", { try await store.requestAnswer(PiAnswer(promptID: "p-1", value: .option("覆盖")), to: target("answer"), on: host) },
             { $0["promptId"] as? String == "p-1" && $0["value"] as? String == "覆盖" }),
            ("config", "config", {
                try await store.requestConfig(PiConfig(model: PiModelKey(provider: "anthropic", id: "opus"), thinking: .high), to: target("config"), on: host)
            }, { $0["model"] as? [String: String] == ["provider": "anthropic", "id": "opus"] && $0["thinking"] as? String == "high" }),
            ("end", "end", { try await store.requestEnd(of: target("end"), on: host) }, { _ in true }),
            ("stop", "abort", { try await store.requestStop(of: target("stop"), on: host) }, { _ in true }),
        ]
        for c in cases {
            let ext = try await rig.host.connect(c.ref, cwd: "/work/app", busy: true)
            let done = try await awaitFinished(try await c.request().id)
            #expect(done.status == .known(.succeeded), "\(c.ref)")
            #expect(ext.received == [c.received], "\(c.ref)")
            #expect(ext.commands.last.map { c.sent($0.json) } == true, "\(c.ref)")
        }
        #expect(rig.host.calls.isEmpty)
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// 发给 Agent 时命令带着卡片（卡片文字是参数）：卡片关联到会话、任务进行中，照样不写发送记录；命令里带图片按失败写回，什么都不交给桥。
    @Test func 斜杠命令带卡片只关联卡片_带图片按失败写回() async throws {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/app")
        let task = try await services.store.createTask("改登录")
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let target = SendTarget(kind: .piSession, name: "app", ref: "sess-1")

        let request = try await services.store.requestDelivery("/greet\n\n改登录", to: target, on: TestApp.hostID, mode: .command, card: task.id)
        _ = try await awaitFinished(request.id)
        let linked = try #require(try await services.store.card(task.id))
        #expect(linked.piSessionID == "sess-1" && linked.status == .inProgress)
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)

        // 图片文件在本机（没到的图片执行器会等它同步过来，那是另一条路径）
        let hash = try services.store.files.store(pngData(shade: 0.3))
        let commands = ext.commands.count
        let image = try await services.store.requestDelivery("/greet\n\n![](cuepad://img/\(hash))", to: target, on: TestApp.hostID, mode: .command)
        #expect(try await awaitFinished(image.id).status == .known(.failed))
        #expect(ext.commands.count == commands)
    }

    /// 已经结束的会话（不在这台 Mac 的桥上）没有可结束的会话、也没有这一轮可停：目标达成，按成功写回，不恢复它、不碰桥。
    @Test(arguments: [DeliveryMode.end, .stop])
    func 结束或停止已经结束的会话直接成功_不恢复(mode: DeliveryMode) async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let target = SendTarget(kind: .piSession, name: "app", ref: "old")
        let request = mode == .end
            ? try await services.store.requestEnd(of: target, on: TestApp.hostID)
            : try await services.store.requestStop(of: target, on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.host.calls.isEmpty)
    }

    /// 手机上停止、结束、改配置：请求都发给会话所在的那台 Mac，写出后立即上传（与发送、作答同一条通路）。
    @Test(.timeLimit(.minutes(1)))
    func 请求停止_结束_改配置写给会话所在的Mac并立即上传() async throws {
        try await PiStateRecorder(store: services.store, hostID: "mac-other").update(sessionID: "far", state: .thinking, title: "远处")
        let session = try #require(try await services.store.allPiSessionStates().first)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()

        let stop = try await services.stop(session)
        #expect(stop.hostID == "mac-other" && stop.mode == .known(.stop) && stop.target.ref == "far")
        #expect(await uploads.next() == stop.id.uuidString.lowercased())

        let end = try await services.end(session)
        #expect(end.hostID == "mac-other" && end.mode == .known(.end) && end.target.ref == "far")
        #expect(await uploads.next() == end.id.uuidString.lowercased())

        let config = try await services.configure(PiConfig(thinking: .low), for: session)
        #expect(config.hostID == "mac-other" && config.config == PiConfig(thinking: .low) && config.target.ref == "far")
        #expect(await uploads.next() == config.id.uuidString.lowercased())
    }

    /// Mac 主动拉取的条件看桥上真的连着的会话，不看资料库里的状态记录（记录可能是没来得及标为结束的旧会话）；
    /// 本机有还没结果的投送请求时也在等。
    @Test(.timeLimit(.minutes(1)))
    func 主动拉取的条件_没有连着的会话时不因旧记录而拉_有本机待执行请求时拉() async throws {
        try await PiStateRecorder(store: services.store, hostID: TestApp.hostID).update(sessionID: "stale", state: .settled, title: "旧会话")
        services.startSpeechClock()
        var waiting = services.pollingCondition().makeAsyncIterator()
        #expect(await waiting.next() == .some(nil))

        _ = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: TestApp.hostID)
        while let next = await waiting.next(), next == nil {}
        #expect(services.pollingCadence == SyncPoller.Cadence(every: .seconds(2)))
    }

    /// Cue 在这台值班也是在等：你在手机上对它说的话、"等你"的回答只经主动拉取到达，会话都关着、没有在路上的请求时也拉。
    @Test(.timeLimit(.minutes(1)))
    func 主动拉取的条件_Cue在这台值班时也拉() async throws {
        #expect(services.pollingCadence == nil)
        try await services.store.updateCueProfile { [hostID = TestApp.hostID] in
            $0.hostID = hostID
            $0.enabledAt = .now
        }
        services.start()
        defer { services.cancelBackgroundWork() }
        try await eventually("Cue 在这台值班") { services.cue.onDuty }
        #expect(services.pi.slots.isEmpty && !services.hasOpenDeliveries)
        #expect(services.pollingCadence == SyncPoller.Cadence(every: .seconds(2)))
    }

    /// 领取与写回结果后各立即只上传这一条，不等引擎调度：手机才能尽早知道 Mac 接手了、拉到结果。
    /// 领取那次在后台任务里传，两次的先后不定：两次都传过才说明结果已写回并传出。
    @Test(.timeLimit(.minutes(1)))
    func 执行器领取与写回结果后各立即上传这一条() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        // 停止一个不在这台桥上的会话：不碰 Pi，当场按成功写回
        let request = try await services.store.requestStop(of: SendTarget(kind: .piSession, name: "不在的会话", ref: "absent"), on: TestApp.hostID)
        var uploads = rig.sync.uploads.stream.makeAsyncIterator()
        let name = request.id.uuidString.lowercased()

        #expect(await uploads.next() == name)
        #expect(await uploads.next() == name)
        #expect(try await services.store.deliveryRequest(request.id)?.isOpen == false)
    }

    @Test func 旧版本写来的发到应用请求按失败写回() async throws {
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .unknown("app"), name: "Ghostty", ref: "com.mitchellh.ghostty"), on: TestApp.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }
}
#endif
