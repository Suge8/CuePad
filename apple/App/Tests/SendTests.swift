#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import CueText
import Foundation
import Testing
@testable import CuePad

@MainActor
struct SendTests {
    let rig = Rig()
    var services: AppServices { rig.services }
    var channels: FakeChannels { rig.channels }
    let png = pngData()

    /// `before\n![](cuepad://img/<哈希>)\nafter`
    func bodyWithImage() async throws -> String {
        let hash = try await services.store.addImage(png).hash
        return "before\n\(CueFormat.imageMarkup(id: hash))\nafter"
    }

    func idleSession(_ id: String = "s1.100", busy: Bool = false) {
        channels.sessions[id] = PiSessionInfo(
            target: SendTarget(kind: .piSession, name: "work", ref: "sess-1"), isBusy: busy)
    }

    // MARK: 路由

    @Test func 剪贴板_文字与图片按原顺序_记录目标为剪贴板() async throws {
        let body = try await bodyWithImage()

        try await services.send(body, to: .clipboard)

        #expect(channels.calls == [.copy(Payload([.text("before\n"), .image(png), .text("\nafter")]))])
        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.targetKind == .clipboard)
        #expect(record.content == body)
    }

    @Test func Pi直发_文字去掉图片标记_图片按序带原图和类型_记录会话id与目录名() async throws {
        idleSession()
        let body = try await bodyWithImage()

        try await services.send(body, to: .pi("s1.100", .send))

        #expect(channels.calls == [
            .send(PiMessage(text: "before\n\nafter", images: [PiImage(mimeType: "image/png", data: png)]), "s1.100")
        ])
        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.targetKind == .piSession)
        #expect(record.targetName == "work")
        #expect(record.targetRef == "sess-1")
    }

    @Test func Pi会话忙时_未指定排队方式则报错_指定后按方式发送() async throws {
        idleSession(busy: true)

        await #expect(throws: SendError.piSessionBusy) {
            try await services.send("hi", to: .pi("s1.100", .send))
        }
        #expect(channels.calls.isEmpty)
        #expect(try await services.store.sendRecords().isEmpty)

        try await services.send("hi", to: .pi("s1.100", .steer))
        #expect(channels.calls == [.send(PiMessage(text: "hi", whenBusy: .steer), "s1.100")])
    }

    @Test func 未知Pi会话报错且不写记录() async throws {
        await #expect(throws: PiBridgeError.unknownSession("nope")) {
            try await services.send("hi", to: .pi("nope", .send))
        }
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 放进输入框只送文字_含图片则拒绝且什么都不发() async throws {
        idleSession()
        try await services.send("plain", to: .pi("s1.100", .paste))
        #expect(channels.calls == [.paste("plain", "s1.100")])

        let body = try await bodyWithImage()
        await #expect(throws: SendError.imagesNotSupported) {
            try await services.send(body, to: .pi("s1.100", .paste))
        }
        #expect(channels.calls.count == 1)
        #expect(try await services.store.sendRecords().count == 1)
    }

    @Test func 通用投送_先预检再隐藏窗口再投送_按设置回车_记录应用名与bundle() async throws {
        let body = try await bodyWithImage()
        services.settings.autoSubmit = true

        try await services.send(body, to: .app(.terminal))

        #expect(channels.calls == [
            .preflight(.terminal),
            .dispatch(Payload([.text("before\n"), .image(png), .text("\nafter")]), .terminal, submit: true),
        ])
        #expect(rig.window.events == ["hide"])
        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.targetKind == .app)
        #expect(record.targetName == "Editor")
        #expect(record.targetRef == "com.example.editor")
    }

    @Test func 通用投送预检失败_窗口不动_没有记录() async throws {
        channels.preflightError = DispatchError.accessibilityRequired

        await #expect(throws: DispatchError.accessibilityRequired) {
            try await services.send("hi", to: .app(.lastFrontmost))
        }
        #expect(rig.window.events.isEmpty)
        #expect(try await services.store.sendRecords().isEmpty)
    }

    @Test func 通用投送失败_窗口恢复_没有记录() async throws {
        channels.dispatchError = DispatchError.targetUnavailable

        await #expect(throws: DispatchError.targetUnavailable) {
            try await services.send("hi", to: .app(.lastFrontmost))
        }
        #expect(rig.window.events == ["hide", "show"])
        #expect(try await services.store.sendRecords().isEmpty)
    }

    // MARK: 记录

    @Test func 记录带内容快照与关联的卡片任务() async throws {
        let card = try await services.store.createCard(in: nil, body: "card body")
        let task = try await services.store.createTask("do it")

        try await services.send("snapshot text", to: .clipboard, card: card.id, task: task.id)

        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.content == "snapshot text")
        #expect(record.cardID == card.id)
        #expect(record.taskID == task.id)
    }

    @Test func 图片文件缺失时报错_不发送不记录() async throws {
        let missing = CueFormat.imageMarkup(id: String(repeating: "a", count: 64))

        await #expect(throws: SendError.imageUnavailable(String(repeating: "a", count: 64))) {
            try await services.send("x \(missing)", to: .clipboard)
        }
        #expect(channels.calls.isEmpty)
        #expect(try await services.store.sendRecords().isEmpty)
    }
}
#endif
