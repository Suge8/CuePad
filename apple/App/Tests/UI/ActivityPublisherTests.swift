#if os(macOS)
import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 中转的替身：收下每份实时活动推送，按主机名分开记（用例并行）。
private nonisolated final class RelayStub: URLProtocol, @unchecked Sendable {
    static let received = Mutex<[String: [Data]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { body.append(buffer, count: count) }
            stream.close()
        }
        Self.received.withLock { $0[request.url!.host()!, default: []].append(body) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.releasesLibraries)
struct ActivityPublisherTests {
    let app = TestApp()
    let relay = "relay-\(UUID().uuidString.lowercased()).test"
    var store: CueStore { app.services.store }

    private struct Push {
        let token: String, priority: Int, aps: [String: Any]
        var event: String { aps["event"] as! String }
    }

    private var pushes: [Push] {
        RelayStub.received.withLock { $0[relay] ?? [] }.map { data in
            let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            return Push(token: json["token"] as! String, priority: json["priority"] as! Int, aps: (json["payload"] as! [String: Any])["aps"] as! [String: Any])
        }
    }

    /// 同真的 App：这台是发布方、同步对过。
    private func recording() async throws -> StateRecorder {
        app.services.startSync()
        try await app.syncs()
        _ = try await store.updateCueProfile { $0.hostID = app.hostID }
        return try await app.runtimeRecorder(on: app.hostID)
    }

    /// 发布任务跟着服务跑，从这一刻算"这台启动"。
    private func publish() -> Task<Void, Never> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStub.self]
        let publisher = ActivityPublisher(host: relay, configuration: configuration), services = app.services!
        return Task { await publisher.run(services) }
    }

    @Test func 手机上没有岛_新开工的远程开一只_登记了地址接着推_没活了结束并清掉() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let recorder = try await recording()
        // 这台启动前就在跑的不为它开：不知道手机上那只是几时没的
        try await recorder.update(sessionID: "old", state: .thinking, title: "old", projectID: project.id)
        try await store.recordActivityStarter(device: "phone", token: "aa11", environment: "production")
        await nextMillisecond()
        let task = publish()
        defer { task.cancel() }
        await quietPeriod(.milliseconds(500))
        #expect(pushes.isEmpty)

        try await recorder.update(sessionID: "zoom", state: .thinking, title: "canvas-zoom", projectID: project.id)
        try await eventually("远程开岛") { pushes.count == 1 }
        let start = pushes[0], alert = try #require(start.aps["alert"] as? [String: Any])
        #expect(start.event == "start" && start.token == "aa11" && start.priority == 10)
        #expect(alert["title"] as? String == "canvas-zoom" && (alert["body"] as? [String: String])?["loc-key"] == "island_start_working")
        #expect(start.aps["attributes-type"] as? String == "CueActivityAttributes" && start.aps["input-push-token"] as? Int == 1)
        #expect((start.aps["attributes"] as? [String: Any])?["remoteUpdates"] as? Bool == true)

        // 手机被唤醒、登记了那只的地址：之后的内容推给它
        try await store.recordActivityDestination(device: "phone", activityID: "A", token: "bb22", environment: "production", startedAt: .now)
        try await eventually("第一份内容") { pushes.count == 2 }
        #expect(pushes[1].event == "update" && pushes[1].token == "bb22" && pushes[1].priority == 10)

        // 又一件开工：一眼看得出的变化，高优先级；岛在，不再开一只
        try await recorder.update(sessionID: "ship", state: .thinking, title: "ship", projectID: project.id)
        try await eventually("多了一件") { pushes.count == 3 }
        #expect(pushes[2].event == "update" && pushes[2].token == "bb22" && pushes[2].priority == 10)

        for session in ["old", "zoom", "ship"] { try await recorder.update(sessionID: session, state: .ended) }
        try await eventually("没活了就结束") { pushes.last?.event == "end" }
        let end = try #require(pushes.last)
        #expect(end.token == "bb22" && end.aps["dismissal-date"] as? Int == end.aps["timestamp"] as? Int)

        // 刚开过一只，马上又有新活：不连着开（系统对远程开岛有额度），留给手机到前台自己开
        let count = pushes.count
        try await recorder.update(sessionID: "next", state: .thinking, title: "next", projectID: project.id)
        await quietPeriod(.milliseconds(1500))
        #expect(pushes.count == count)
    }

    @Test func 快到系统上限_结束并清掉_还在跑的那件不立刻续开() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let recorder = try await recording(), task = publish()
        defer { task.cancel() }
        try await store.recordActivityStarter(device: "phone", token: "aa11", environment: "production")
        try await store.recordActivityDestination(
            device: "phone", activityID: "A", token: "bb22", environment: "production",
            startedAt: .now.addingTimeInterval(ActivityDestination.retireLead / 2 - ActivityDestination.lifetime))
        try await recorder.update(sessionID: "zoom", state: .thinking, title: "canvas-zoom", projectID: project.id)
        try await eventually("到点前收掉") { !pushes.isEmpty }
        let end = pushes[0]
        #expect(end.event == "end" && end.token == "bb22" && end.aps["dismissal-date"] as? Int == end.aps["timestamp"] as? Int)
        await quietPeriod(.milliseconds(1500))
        #expect(pushes.count == 1)
    }
}
#endif
