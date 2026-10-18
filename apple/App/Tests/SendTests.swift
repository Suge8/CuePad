#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

struct SendTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    let png = pngData()

    /// `before\n![](cuepad://img/<哈希>)\nafter`
    func bodyWithImage() async throws -> String {
        let hash = try services.store.files.store(png)
        return "before\n\(CueFormat.imageMarkup(id: hash))\nafter"
    }

    /// 发给 Pi 走本机投送请求：会话要连着桥，执行器要在运行。
    func connectedSession(busy: Bool = false) async throws -> FakeExtension {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/work", busy: busy)
        try await services.executor.start()
        return ext
    }

    /// 等唯一的那条请求有结果。
    func settled() async throws -> DeliveryRequest {
        try await eventually(services.store, { try $0.deliveryRequests().first }) { $0?.isOpen == false }!
    }

    // MARK: 路由

    @Test func 复制_文字与图片按原顺序放进剪贴板_不是发送不记发送记录() async throws {
        let body = try await bodyWithImage()

        try services.copy(body)

        #expect(rig.pasteboard.string(forType: .string) == "before\n\nafter")
        #expect(rig.pasteboard.data(forType: .rtfd) != nil)
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// 发给 Pi 的东西不论从哪台设备发都只有一种记录：Mac 上发（会话详情、卡片的发送按钮、菜单栏）写一条指定本机的投送请求，写出就返回、
    /// 不等送达，由本机执行器照远端请求的流程执行；会话收到去掉图片标记的文字与按序的原图，资料库里只多这条请求与它的发送记录
    /// （内容快照、关联的卡片、会话 id 与目录名）。
    @Test(.timeLimit(.minutes(1)))
    func Mac发给Pi会话_写本机投送请求由执行器送达_只多一条请求与一条发送记录() async throws {
        let ext = try await connectedSession()
        let body = try await bodyWithImage()
        let task = try await services.store.createTask("do it", in: nil)

        #expect(Workspace(services: services).send(body, to: AgentTarget(session: ext.sessionID, mode: .steer), card: task.id))

        let request = try await settled()
        #expect(request.status == .known(.succeeded))
        #expect(request.hostID == TestApp.hostID)
        #expect(request.target == SendTarget(kind: .piSession, name: "work", ref: "sess-1"))
        #expect(ext.messages == [
            PiMessage(text: "before\n\nafter", images: [PiImage(mimeType: "image/png", data: png)], whenBusy: .steer, deliveryID: request.id.uuidString)
        ])
        #expect(try await services.store.deliveryRequests().count == 1)
        let records = try RawDB(services.location.databaseURL).rows("SELECT targetKind, targetName, targetRef, content, cardID FROM sendRecords")
        #expect(records == [["piSession", "work", "sess-1", body, task.id.uuidString.lowercased()]])
    }

    @Test func Pi会话忙时_直接发送先问马上说还是等它做完再说_不写请求_选了按方式发送() async throws {
        let ext = try await connectedSession(busy: true)
        let workspace = Workspace(services: services)

        #expect(!workspace.send("hi", to: AgentTarget(session: ext.sessionID)))
        #expect(workspace.sendState.busy?.text == "hi")
        #expect(try await services.store.deliveryRequests().isEmpty)

        workspace.resolveBusySend(.steer)
        let request = try await settled()
        #expect(request.mode == .known(.steer))
        #expect(ext.messages == [PiMessage(text: "hi", whenBusy: .steer, deliveryID: request.id.uuidString)])
    }

    /// 回复框看到会话歇着、写了直接发送，Mac 执行时会话已经开始了一轮（库里的记录过时）：不报错，按等它做完再说送达
    /// （桥缺省就是等它做完再说），会话页那句是已送达。
    @Test func 直接发送时会话刚忙起来_按等它做完再说送达() async throws {
        let ext = try await connectedSession(busy: true)
        let session = try #require(services.pi.session(sessionID: ext.sessionID))
        _ = await Workspace(services: services).speak("hi", to: .session(session.sendTarget, host: TestApp.hostID, mode: .send, card: nil)).value

        let request = try await settled()
        #expect(Said.request(request).trip(at: .always(at: .now)) == .delivered)
        #expect(ext.messages == [PiMessage(text: "hi", whenBusy: nil, deliveryID: request.id.uuidString)])
    }

    /// 桥上没有、记录里也不在线的会话当作已结束：写给本机，由执行器去唤醒；这台 Mac 上没有它的会话文件就带原因没能送达，不记发送。
    @Test func 不在这台Mac上的会话_没能送达带原因且不记发送() async throws {
        try await services.executor.start()

        #expect(Workspace(services: services).send("hi", to: AgentTarget(session: "nope")))

        #expect(try await settled().failure != nil)
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// Cue 发进会话的话（投送请求 origin 是 cue）送达、请求清理之后，会话页里那条消息仍标着 Cue：认的是发送记录，不是请求。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func Cue发进会话的话_请求清理之后会话页仍标着Cue() async throws {
        let ext = try await connectedSession()
        let store = services.store
        let request = try await store.requestDelivery(
            "跑一遍测试", to: SendTarget(kind: .piSession, name: "work", ref: ext.sessionID), on: TestApp.hostID, cue: true)
        for try await status in store.observe({ try $0.deliveryRequest(request.id)?.status }) {
            if status == .known(.succeeded) { break }
        }
        try await store.deleteDelivery(request.id)
        let said = PiChatMessage(sessionID: ext.sessionID, entryID: "u0", seq: 0, role: .user, text: "跑一遍测试", at: .now, deliveryID: request.id)
        try await store.writePiTranscript(PiTranscript(sessionID: ext.sessionID, messages: [said], recap: PiRecap(lastPrompt: said.text)))

        let digest = try await SessionDigest.read(PiSessionState.recordID(sessionID: ext.sessionID), sessionID: ext.sessionID, from: store)
        let derived = ChatDerived()
        derived.refresh(digest)

        #expect(digest.deliveries.isEmpty)
        let entry = try #require(derived.items.first)
        #expect(entry.fromCue)
    }

    @Test func 复制时图片文件缺失就报错_剪贴板不动() async throws {
        let missing = CueFormat.imageMarkup(id: String(repeating: "a", count: 64))
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("原有", forType: .string)

        #expect(throws: SendError.imageUnavailable(String(repeating: "a", count: 64))) {
            try services.copy("x \(missing)")
        }
        #expect(rig.pasteboard.string(forType: .string) == "原有")
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }
}
#endif
