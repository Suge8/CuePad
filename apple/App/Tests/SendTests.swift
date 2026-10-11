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

    // MARK: 路由

    @Test func 复制_文字与图片按原顺序放进剪贴板_不是发送不记发送记录() async throws {
        let body = try await bodyWithImage()

        try services.copy(body)

        #expect(rig.pasteboard.string(forType: .string) == "before\n\nafter")
        #expect(rig.pasteboard.data(forType: .rtfd) != nil)
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 发给Pi_文字去掉图片标记_图片按序带原图和类型_记录会话id与目录名() async throws {
        let ext = try await connectedSession()
        let body = try await bodyWithImage()

        try await services.send(body, to: ext.id, mode: .send, card: nil)

        let request = try #require(try await services.store.deliveryRequests().first)
        #expect(ext.messages == [
            PiMessage(text: "before\n\nafter", images: [PiImage(mimeType: "image/png", data: png)], deliveryID: request.id.uuidString)
        ])
        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.targetKind == .known(.piSession))
        #expect(record.targetName == "work")
        #expect(record.targetRef == "sess-1")
    }

    @Test func Pi会话忙时_未指定马上说还是等它做完再说则报错_指定后按方式发送() async throws {
        let ext = try await connectedSession(busy: true)

        await #expect(throws: SendError.piSessionBusy) {
            try await services.send("hi", to: ext.id, mode: .send, card: nil)
        }
        #expect(ext.commands.isEmpty)
        #expect(try await services.store.sendRecords().isEmpty)

        try await services.send("hi", to: ext.id, mode: .steer, card: nil)
        let request = try #require(try await services.store.deliveryRequests().first)
        #expect(ext.messages == [PiMessage(text: "hi", whenBusy: .steer, deliveryID: request.id.uuidString)])
    }

    @Test func 未知Pi会话报错且不写记录() async throws {
        await #expect(throws: PiBridgeError.unknownSession("nope")) {
            try await services.send("hi", to: "nope", mode: .send, card: nil)
        }
        #expect(try await services.store.sendRecords().isEmpty)
    }

    // MARK: Mac 上发给 Pi 会话

    /// 发给 Pi 的东西不论从哪台设备发都只有一种记录：Mac 上发（会话详情、卡片的发送按钮、菜单栏）写一条指定本机的投送请求，
    /// 由本机执行器照远端请求的流程执行；送达后资料库里只多这条请求与它的发送记录。
    @Test(.timeLimit(.minutes(1)))
    func Mac发给Pi会话_写本机投送请求由执行器送达_只多一条请求与一条发送记录() async throws {
        let ext = try await connectedSession()
        let workspace = Workspace(services: services)

        #expect(await workspace.send("hi", to: AgentTarget(session: ext.sessionID, mode: .steer)))

        // 发出即有请求（"你发过去的"列表立刻有这一行）
        let request = try #require(try await services.store.deliveryRequests().first)
        #expect(request.hostID == TestApp.hostID)
        #expect(request.target == SendTarget(kind: .piSession, name: "work", ref: "sess-1"))
        #expect(request.mode == .known(.steer))
        for try await status in services.store.observe({ try $0.deliveryRequest(request.id)?.status }) {
            if status == .known(.succeeded) { break }
        }
        #expect(ext.messages == [PiMessage(text: "hi", whenBusy: .steer, deliveryID: request.id.uuidString)])
        #expect(try await services.store.deliveryRequests().count == 1)
        let record = try #require(try await services.store.sendRecords().first)
        #expect(try await services.store.sendRecords().count == 1)
        #expect(record.targetRef == "sess-1")
    }

    // MARK: 记录

    @Test func 记录带内容快照与关联的卡片() async throws {
        let ext = try await connectedSession()
        let task = try await services.store.createTask("do it", in: nil)

        try await services.send("snapshot text", to: ext.id, mode: .send, card: task.id)

        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.content == "snapshot text")
        #expect(record.cardID == task.id)
    }

    @Test func 复制时图片文件缺失就报错_剪贴板不动() async throws {
        let missing = CueFormat.imageMarkup(id: String(repeating: "a", count: 64))
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("原有", forType: .string)

        #expect(throws: SendError.imageUnavailable(String(repeating: "a", count: 64))) {
            try services.copy("x \(missing)")
        }
        #expect(rig.pasteboard.string(forType: .string) == "原有")
        #expect(try await services.store.sendRecords().isEmpty)
    }
}
#endif
