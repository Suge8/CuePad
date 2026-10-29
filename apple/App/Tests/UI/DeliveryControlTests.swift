#if os(macOS)
import CueAgent
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

/// #43：一次未知不授权重投旧请求，也不能永久锁住用户明确发起的新控制意图。
@MainActor
struct DeliveryControlTests {
    @Test(arguments: [DeliveryMode.send, .start], [
        ("unconfirmed", false), ("unconfirmed", true), ("future-outcome", false), ("future-outcome", true),
    ])
    func 交接未收尾时Cue再开工不能悄悄再发或再开(mode: DeliveryMode, outcome: (String, Bool)) async throws {
        let (status, fresh) = outcome
        let app = TestApp(), store = app.services.store
        defer { app.services.cancelBackgroundWork() }
        let host = "mac-delivery"
        try await store.recordMacAgents(host: host, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: [])])
        let recorder = try await app.runtimeRecorder(on: host)
        try await recorder.update(sessionID: "atlas", state: .settled)
        let parent = try await store.createTask("发布")
        let first = try await store.createTask("准备", under: parent.id)
        try await store.bindSession("atlas", to: first.id)
        let task = try await store.createTask("上传结果", under: parent.id)
        try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let target = SendTarget(kind: .piSession, name: "发布", ref: mode == .start ? nil : "atlas")
        let text = mode == .start ? PiLaunch(project: Project.defaultID, prompt: task.body, token: UUID().uuidString).stored : task.body
        await Workspace(services: app.services).speak(text, to: .session(target, host: host, mode: mode, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first)
        // 写回前崩溃／丢回执：已交出的原意图留在库里，未确认不是未开工。
        try RawDB(app.services.location.databaseURL).exec(
            "UPDATE deliveryRequests SET status = '\(status)', handledBy = '\(host)', completedAt = createdAt WHERE id = '\(request.id.uuidString.lowercased())'")
        let occupied = try #require(try await store.handoffRequests(for: [task.id])[task.id])
        #expect(occupied.map(\.id) == [request.id])
        #expect(occupied.allSatisfy { !Speech.trip($0, at: .always()).inTransit })
        let args: [String: Any] = ["action": "start", "task": task.id.uuidString, "fresh": fresh]
        let result = try #require(await CueTools(store: store, wait: 0).call("task", args))
        #expect(result.isError)
        #expect(try await store.deliveryRequests().map(\.id) == [request.id])
    }

    @Test(arguments: [DeliveryMode.retry, .end])
    func 未确认后再次点控制是新意图_原请求保留_宿主仍保护实际执行(mode: DeliveryMode) async throws {
        let app = TestApp(), store = app.services.store
        let ext = try await app.host.connect("atlas", cwd: app.directory.path)
        ext.onCommand = { [weak ext] _, command in
            guard let kind = command["t"] as? String, kind == "retry" || kind == "end" else { return ["ok": true] }
            let count = ext?.commands.filter { $0.json["t"] as? String == kind }.count ?? 0
            guard count > 1 else { return nil }
            if kind == "end" { ext?.closeAfterReply(bye: "quit") }
            return ["ok": true]
        }
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: "atlas", state: .error, detail: "fetch failed", failure: .network)
        let session = try #require(try await store.allPiSessionStates().first)
        let workspace = Workspace(services: app.services)
        if mode == .retry { await workspace.retry(session).value } else { await workspace.end(session) }
        let first = try #require(try await store.deliveryRequests().first)
        try await app.services.executor.start()
        let uncertain = try await store.outcome(of: first)
        #expect(uncertain.status == .known(.unconfirmed))
        if mode == .retry {
            #expect(PiDelivery.phase(of: uncertain, for: session, at: .always()) == nil)
            #expect(workspace.shownInHeader(session, delivery: uncertain).status == .failed(.network))
            await workspace.retry(session).value
        } else {
            #expect(DeliveryRequest.shownEnd(in: [uncertain], at: .always())?.inTransit != true)
            await workspace.end(session)
        }
        let second = try #require(try await store.deliveryRequests().first { $0.id != first.id })
        #expect(try await store.outcome(of: second).status == .known(.succeeded))
        #expect(try await store.deliveryRequest(first.id)?.status == .known(.unconfirmed))
        #expect(ext.received.filter { $0 == mode.rawValue }.count == 2)
        await app.services.executor.beginStop()()
    }
}
#endif
