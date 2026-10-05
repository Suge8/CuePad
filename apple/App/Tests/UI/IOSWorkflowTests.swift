#if os(iOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

/// iOS 界面的三条跨边界合同：发到 Mac 的请求形状（Mac 执行器按它执行）、活动页的会话顺序与角标、随手记带图入库。
@MainActor
struct IOSWorkflowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func session(_ id: String, _ state: PiWorkState, host: String = "mac-a", detail: String? = nil) async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: id, state: state, detail: detail, title: id)
        return try #require(try await store.allPiSessionStates().first { $0.sessionID == id })
    }

    // MARK: 发到 Mac

    /// 手机主动拉取的节奏：有发往 Mac 还没结果的请求时 2 秒、每次在等最多 2 分钟；正在看 Pi 页或会话近况时 3 秒、不限时；
    /// 两者都有时 2 秒、不限时。
    @Test func 主动拉取的节奏_等结果与看着Pi页() {
        let services: AppServices = app.services
        #expect(services.pollingCadence == nil)
        services.piViewers = 1
        #expect(services.pollingCadence == SyncPoller.Cadence(interval: .seconds(3)))
        services.hasOpenDeliveries = true
        #expect(services.pollingCadence == SyncPoller.Cadence(interval: .seconds(2)))
        services.piViewers = 0
        #expect(services.pollingCadence == SyncPoller.Cadence(interval: .seconds(2), limit: .seconds(120)))
    }

    @Test func 作答_请求发给会话所在的Mac_带这次弹窗的标识与答案() async throws {
        let question = PiQuestion(promptID: "p-7", kind: .select, text: "覆盖吗？", options: ["覆盖", "取消"])
        try await PiStateRecorder(store: store, hostID: "mac-b").update(
            sessionID: "atlas", state: .waitingForUser, title: "atlas", recap: PiRecap(question: question))
        let session = try #require(try await store.allPiSessionStates().first)

        let request = try await app.services.answer(.option("覆盖"), to: session)

        #expect(request.hostID == "mac-b" && request.mode == .known(.answer))
        #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "atlas"))
        #expect(request.answer == PiAnswer(promptID: "p-7", value: .option("覆盖")))
    }

    @Test func 发到Mac_请求指定会话所在的Mac_目标是该会话_方式原样交给Mac() async throws {
        let target = try await session("atlas", .settled, host: "mac-b")

        for mode in [DeliveryMode.send, .steer, .followUp, .paste] {
            let request = try await app.services.requestMacDelivery("正文", to: target, mode: mode)
            #expect(request.hostID == "mac-b")
            #expect(request.target == SendTarget(kind: .piSession, name: "atlas", ref: "atlas"))
            #expect(request.mode == .known(mode))
            #expect(request.status == .known(.pending))
        }
    }

    @Test(arguments: [
        (PiWorkState.settled, false, [DeliveryMode.send, .paste]),
        (.error, false, [.send, .paste]),
        (.thinking, false, [.steer, .followUp, .paste]),
        (.tool, false, [.steer, .followUp, .paste]),
        (.waitingForUser, false, [.steer, .followUp, .paste]),
        // 等子代理：算工作中，但 Pi 自己这轮已经歇下，消息直接开始新的一轮（与 Mac 同一条规则）
        (.delegating, false, [.send, .paste]),
        (.settled, true, [.send]),
        (.outputting, true, [.steer, .followUp]),
    ])
    func 发送方式_会话忙时插话或排队_含图片不能放进输入框(state: PiWorkState, hasImages: Bool, modes: [DeliveryMode]) {
        #expect(MacDelivery.modes(for: .known(state), hasImages: hasImages) == modes)
    }

    // MARK: Pi 页

    @Test func Pi页_等你确认_出错_工作中_空闲_已结束依次排() async throws {
        _ = try await session("done", .ended)
        _ = try await session("idle", .settled)
        _ = try await session("busy", .tool, detail: "bash")
        _ = try await session("ask", .waitingForUser, detail: "要覆盖吗？")
        _ = try await session("broken", .error)

        let ordered = PiSessionState.inListOrder(try await store.allPiSessionStates())

        #expect(ordered.map(\.sessionID) == ["ask", "broken", "busy", "idle", "done"])
    }

    // MARK: 随手记

    @Test func 随手记带图_存为一张卡_文字在前图片按顺序在后_落在指定项目() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services, holder: SceneContext())
        let first = pngData(shade: 0.1), second = pngData(shade: 0.9)
        let hashes = try [first, second].map { try app.services.images.store($0) }

        let card = try await CaptureDraft(text: "  想法  ", images: [first, second]).save(in: project.id, workspace: workspace)

        #expect(card.projectID == project.id)
        #expect(card.body == "想法\n\n![](cuepad://img/\(hashes[0]))\n![](cuepad://img/\(hashes[1]))")
        #expect(try await store.cards(in: project.id).map(\.id) == [card.id])
    }

    @Test func 随手记只有图片_也能存() async throws {
        let workspace = Workspace(services: app.services, holder: SceneContext())
        let image = pngData()
        let hash = try app.services.images.store(image)

        let card = try await CaptureDraft(text: "", images: [image]).save(in: nil, workspace: workspace)

        #expect(card.projectID == nil)
        #expect(card.body == "![](cuepad://img/\(hash))")
    }
}
#endif
