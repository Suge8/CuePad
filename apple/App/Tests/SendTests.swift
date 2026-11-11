#if os(macOS)
import CueBridge
import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SendTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    let png = pngData()

    func bodyWithImage() async throws -> String {
        let hash = try services.store.files.store(png)
        return "before\n\(CueFormat.imageMarkup(key: hash))\nafter"
    }

    func connectedSession() async throws -> FakeExtension {
        let ext = try await rig.host.connect("sess-1", cwd: "/work/work")
        try await services.executor.start()
        return ext
    }

    func settled() async throws -> DeliveryRequest {
        try await eventually(services.store, { try $0.deliveryRequests().first }) { $0?.isOpen == false }!
    }

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
            SessionMessage(text: "before\n\nafter", images: [MessageImage(mimeType: "image/png", data: png)], deliveryID: request.id.uuidString)
        ])
        #expect(try await services.store.deliveryRequests().count == 1)
        let records = try RawDB(services.location.databaseURL).rows("SELECT targetKind, targetName, targetRef, content, cardID FROM sendRecords")
        #expect(records == [["piSession", "work", "sess-1", body, task.id.uuidString.lowercased()]])
    }
}
#endif
