#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import CueText
import Foundation
import SQLite3
import Testing
@testable import CuePad

@MainActor
struct SendTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var channels: FakeChannels { rig.channels }
    let png = pngData()

    /// `before\n![](cuepad://img/<哈希>)\nafter`
    func bodyWithImage() async throws -> String {
        let hash = try services.store.files.store(png)
        return "before\n\(CueFormat.imageMarkup(id: hash))\nafter"
    }

    func idleSession(_ id: String = "s1.100", busy: Bool = false) {
        channels.sessions[id] = PiSessionInfo(
            target: SendTarget(kind: .piSession, name: "work", ref: "sess-1"), isBusy: busy)
    }

    /// 发给 Pi 走本机投送请求：会话要能从 Pi 的会话 id 找回桥上的连接，执行器要在运行。
    func connectedSession(busy: Bool = false) async throws {
        idleSession(busy: busy)
        channels.bridgeIDs["sess-1"] = "s1.100"
        try await services.startDeliveryExecutor()
    }

    // MARK: 路由

    @Test func 剪贴板_文字与图片按原顺序_记录目标为剪贴板() async throws {
        let body = try await bodyWithImage()

        try await services.send(body, to: .clipboard)

        #expect(channels.calls == [.copy(Payload([.text("before\n"), .image(png), .text("\nafter")]))])
        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.targetKind == .known(.clipboard))
        #expect(record.content == body)
    }

    @Test func 发给Pi_文字去掉图片标记_图片按序带原图和类型_记录会话id与目录名() async throws {
        try await connectedSession()
        let body = try await bodyWithImage()

        try await services.send(body, to: .pi("s1.100", .send))

        #expect(channels.calls == [
            .send(PiMessage(text: "before\n\nafter", images: [PiImage(mimeType: "image/png", data: png)]), "s1.100")
        ])
        let record = try #require(try await services.store.sendRecords().first)
        #expect(record.targetKind == .known(.piSession))
        #expect(record.targetName == "work")
        #expect(record.targetRef == "sess-1")
    }

    @Test func Pi会话忙时_未指定马上说还是等它做完再说则报错_指定后按方式发送() async throws {
        try await connectedSession(busy: true)

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
        try await connectedSession()
        try await services.send("plain", to: .pi("s1.100", .paste))
        #expect(channels.calls == [.paste("plain", "s1.100")])

        let body = try await bodyWithImage()
        await #expect(throws: SendError.notDelivered(SendError.imagesNotSupported.localizedDescription)) {
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
        #expect(record.targetKind == .known(.app))
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

    /// 选定的应用退出后，发送按钮仍显示它的名字：按 bundle ID 找已安装的应用，不要求它在运行。
    @Test func 应用名按bundle_ID从已安装的应用解析_找不到才用bundle_ID() {
        // 系统自带应用的显示名随系统语言变化（Safari 在中文系统叫"Safari浏览器"），用名称不随语言变的 CuePad 自己
        #expect(services.appName(bundleID: AppServices.bundleID) == "CuePad")
        #expect(services.appName(bundleID: "com.example.not-installed") == "com.example.not-installed")
    }

    // MARK: Mac 上发给 Pi 会话

    /// 发给 Pi 的东西不论从哪台设备发都只有一种记录：Mac 上发（会话详情、卡片的发送按钮、菜单栏）写一条指定本机的投送请求，
    /// 由本机执行器照远端请求的流程执行；送达后资料库里只多这条请求与它的发送记录。
    @Test(.timeLimit(.minutes(1)))
    func Mac发给Pi会话_写本机投送请求由执行器送达_只多一条请求与一条发送记录() async throws {
        idleSession()
        channels.bridgeIDs["sess-1"] = "s1.100"
        try await services.startDeliveryExecutor()
        let workspace = Workspace(services: services)

        #expect(await workspace.send("hi", via: .pi("s1.100", .steer)))

        // 发出即有请求（"你发过去的"列表立刻有这一行）
        let request = try #require(try await services.store.deliveryRequests().first)
        #expect(request.hostID == TestApp.hostID)
        #expect(request.target == SendTarget(kind: .piSession, name: "work", ref: "sess-1"))
        #expect(request.mode == .known(.steer))
        for try await status in services.store.observe([.deliveryRequests], { try $0.deliveryRequest(request.id)?.status }) {
            if status == .known(.succeeded) { break }
        }
        #expect(channels.calls == [.send(PiMessage(text: "hi", whenBusy: .steer, deliveryID: request.id.uuidString), "s1.100")])
        #expect(try await services.store.deliveryRequests().count == 1)
        let record = try #require(try await services.store.sendRecords().first)
        #expect(try await services.store.sendRecords().count == 1)
        #expect(record.targetRef == "sess-1")
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

    /// 投送已经成功、发送记录没写进去：调用方得到说明这件事的错误（界面据此提示且不当作没发出），而不是只进日志。
    @Test func 已发出但记录写入失败_抛出未记录错误() async throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        try #require(sqlite3_open(services.location.databaseURL.path, &handle) == SQLITE_OK)
        try #require(sqlite3_exec(handle, "DROP TABLE sendRecords", nil, nil, nil) == SQLITE_OK)

        await #expect {
            try await services.send("hi", to: .clipboard)
        } throws: { error in
            if case SendError.unrecorded = error { true } else { false }
        }
        #expect(channels.calls == [.copy(Payload([.text("hi")]))])
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
