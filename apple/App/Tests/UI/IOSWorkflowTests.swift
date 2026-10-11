#if os(iOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

/// iOS 界面的三条跨边界合同：发到 Mac 的请求形状（Mac 执行器按它执行）、活动页的会话顺序与角标、随手记带图入库。
struct IOSWorkflowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func session(_ id: String, _ state: PiWorkState, host: String = "mac-a", detail: String? = nil) async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: id, state: state, detail: detail, title: id)
        return try #require(try await store.allPiSessionStates().first { $0.sessionID == id })
    }

    // MARK: 发到 Mac

    @Test func 作答_请求发给会话所在的Mac_带这次弹窗的标识与答案() async throws {
        let question = PiQuestion(promptID: "p-7", kind: .select, text: "覆盖吗？", options: ["覆盖", "取消"])
        try await PiStateRecorder(store: store, hostID: "mac-b").update(
            sessionID: "atlas", state: .waitingForUser, title: "atlas", question: question)
        let session = try #require(try await store.allPiSessionStates().first)

        let request = try await app.services.answer(.option("覆盖"), to: session)

        #expect(request.hostID == "mac-b" && request.mode == .known(.answer))
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "atlas"))
        #expect(request.answer == PiAnswer(promptID: "p-7", value: .option("覆盖")))
    }

    @Test(arguments: [DeliveryMode.send, .steer, .followUp])
    func 发到Mac_请求指定会话所在的Mac_目标是该会话_方式原样交给Mac(mode: DeliveryMode) async throws {
        let target = try await session("atlas", .settled, host: "mac-b")
        let request = try await app.services.requestMacDelivery("正文", to: target, mode: mode)
        #expect(request.hostID == "mac-b")
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "atlas"))
        #expect(request.mode == .known(mode))
        #expect(request.status == .known(.pending))
    }

    /// 手机上只有一个发送：空闲直接发；Pi 正在跑一轮时默认等它做完再说，另有马上说。
    /// 手机不给"放进输入框"（人不在 Mac 前，没人去按那一下发送）。
    @Test(arguments: [
        (PiWorkState.settled, [DeliveryMode.send]),
        (.error, [.send]),
        (.thinking, [.followUp, .steer]),
        (.tool, [.followUp, .steer]),
        (.waitingForUser, [.followUp, .steer]),
        // 等子代理：算工作中，但 Pi 自己这轮已经歇下，消息直接开始新的一轮（与 Mac 同一条规则）
        (.delegating, [.send]),
        (.outputting, [.followUp, .steer]),
        // 在压缩上下文：Pi 忙着，话等压完再进（扩展在手动压缩期间替它留着）
        (.compacting, [.followUp, .steer]),
        // 已结束的也能直接发：Mac 在后台把它恢复起来再送达
        (.ended, [.send]),
    ])
    func 发给会话_空闲直接发_忙时默认等它做完再说另有马上说(state: PiWorkState, modes: [DeliveryMode]) {
        let session = PiSessionState(
            id: UUID(), sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now, modifiedAt: .now)
        #expect(MacDelivery.modes(for: session) == modes)
    }

    // MARK: Agent 页

    // MARK: 随手记

    @Test func 随手记带图_存为一张卡_文字在前图片按顺序在后_落在指定项目并提示落点() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services)
        let first = pngData(shade: 0.1), second = pngData(shade: 0.9)
        let hashes = try [first, second].map { try app.services.store.files.store($0) }

        try await CaptureDraft(text: "  想法  ", images: [first, second]).save(in: project.id, workspace: workspace)

        let card = try #require(try await store.cards(in: project.id).first)
        #expect(card.body == "想法\n\n![](cuepad://img/\(hashes[0]))\n![](cuepad://img/\(hashes[1]))")
        #expect(workspace.notice?.text == "已记到 圆桌")
        #expect(workspace.notice?.link == .project(project.id))
    }

    @Test func 随手记只有图片_也能存_没选项目进未分类() async throws {
        let workspace = Workspace(services: app.services)
        let image = pngData()
        let hash = try app.services.store.files.store(image)

        try await CaptureDraft(text: "", images: [image]).save(in: nil, workspace: workspace)

        #expect(try await store.cards(in: nil).map(\.body) == ["![](cuepad://img/\(hash))"])
        #expect(workspace.notice?.text == "已记到 未分类")
        #expect(workspace.notice?.link == .unfiled)
    }
}
#endif
