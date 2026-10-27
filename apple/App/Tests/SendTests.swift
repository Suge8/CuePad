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

    /// `before\n![](cuepad://file/<哈希>)\nafter`
    func bodyWithImage() async throws -> String {
        let hash = try services.store.files.store(png)
        return "before\n\(CueFormat.imageMarkup(key: hash))\nafter"
    }

    /// 发给 Pi 走本机投送请求：会话要连着桥，执行器要在运行。
    func connectedSession() async throws -> FakeExtension {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/work")
        try await services.executor.start()
        return ext
    }

    func settled() async throws -> DeliveryRequest {
        try await eventually(services.store, { try $0.deliveryRequests().first }) { $0?.isOpen == false }!
    }

    /// 发给 Pi 的东西不论从哪台设备发都只有一种记录：Mac 上发（会话详情、卡片的发送按钮、菜单栏）写一条指定本机的投送请求，写出就返回、
    /// 不等送达，由本机执行器照远端请求的流程执行；会话收到去掉图片标记的文字与按序的原图，资料库里只多这条请求与它的发送记录
    /// （内容快照、关联的卡片、会话 id 与目录名）。
    @Test
    func Mac发给Pi会话_写本机投送请求由执行器送达_只多一条请求与一条发送记录() async throws {
        let ext = try await connectedSession()
        let body = try await bodyWithImage()
        let task = try await services.store.createTask("do it")

        Workspace(services: services).send(body, to: AgentTarget(session: ext.sessionID), card: task.id)

        let request = try await settled()
        #expect(request.status == .known(.succeeded))
        #expect(request.hostID == TestApp.hostID && request.handledBy == TestApp.hostID)
        #expect(request.target == SendTarget(kind: .piSession, name: "work", ref: "sess-1"))
        #expect(ext.messages == [
            PiMessage(text: "before\n\nafter", images: [PiImage(mimeType: "image/png", data: png)], deliveryID: request.id.uuidString)
        ])
        #expect(try await services.store.deliveryRequests().count == 1)
        let records = try RawDB(services.location.databaseURL).rows("SELECT targetKind, targetName, targetRef, content, cardID FROM sendRecords")
        #expect(records == [["piSession", "work", "sess-1", body, task.id.uuidString.lowercased()]])
    }
}
#endif
