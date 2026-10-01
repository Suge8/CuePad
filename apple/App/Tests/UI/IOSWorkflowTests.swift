#if os(iOS)
import CueStore
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
        return try #require(try await store.piSessionStates().first { $0.sessionID == id })
    }

    // MARK: 发到 Mac

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
        (.settled, true, [.send]),
        (.outputting, true, [.steer, .followUp]),
    ])
    func 发送方式_会话忙时插话或排队_含图片不能放进输入框(state: PiWorkState, hasImages: Bool, modes: [DeliveryMode]) {
        #expect(MacDelivery.modes(for: .known(state), hasImages: hasImages) == modes)
    }

    // MARK: 活动

    @Test func 活动页_等你确认在最前_其次运行中_空闲最后_角标只计等你确认() async throws {
        _ = try await session("idle", .settled)
        _ = try await session("busy", .tool, detail: "bash")
        _ = try await session("ask1", .waitingForUser, detail: "要覆盖吗？")
        _ = try await session("broken", .error)
        _ = try await session("ask2", .waitingForUser)

        let data = try await ActivityData.read(from: store)

        #expect(Set(data.waiting.map(\.sessionID)) == ["ask1", "ask2"])
        #expect(data.running.map(\.sessionID) == ["busy"])
        #expect(Set(data.idle.map(\.sessionID)) == ["idle", "broken"])
        #expect(data.badge == 2)
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
