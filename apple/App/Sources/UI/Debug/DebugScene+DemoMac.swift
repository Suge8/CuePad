#if DEBUG
import CueStore
import CueText
import Foundation
import Observation

extension DebugScene {
    /// 各台演示 Mac 对额度刷新请求按"没有在线的 Pi 会话"写回（同 Mac 上会话还没连好时），画面等到明细里没查到那一行出来才算就绪。
    private static let quotaFails = args.quotaOpts.fails

    static func runDemoMac(_ services: AppServices) async {
        let store = services.store, host = "demo-mac"
        if quotaFails {
            // 别的演示 Mac（demo-mini）上也有在线会话：同样按没查到写回，不然手机一直等它（没人领取的请求由投送层收尾）
            for other in services.quotaRefreshKey where other != host {
                let executor = DeliveryExecutor(store: store, hostID: other, onIssue: { _ in }) { request, _ in
                    request.mode == .known(.quota) ? .failed(ShownText("这台 Mac 上没有在线的 Pi 会话")) : .succeeded
                }
                await running("演示 Mac 答额度") { try await executor.start() }
            }
            holdingReady {
                for await failed in Observations({ if case .failed = services.accountQuotas.phase { true } else { false } }) where failed { return }
            }
        }
        func reachable() async {
            for await offline in Observations({ services.syncState.status == .offline }) where !offline { return }
        }
        Task {
            await running("演示 Mac 交给 Cue") {
                // 每次变化都重读此刻还没交出去的：攒下的旧变化不再各等一遍
                for try await waiting in store.observe({ try toDemoCue($0) }) where !waiting.isEmpty {
                    guard try await !toDemoCue(store).isEmpty else { continue }
                    await reachable()
                    try await Task.sleep(for: .seconds(1.5))
                    try await store.markCueMessagesDelivered(toDemoCue(store))
                    try await demoCueAnswers(store)
                }
            }
        }
        await running("演示 Mac 接手") {
            for try await pending in store.observe({ store in
                try store.deliveryRequests().filter { $0.hostID == host && $0.status == .known(.pending) }.map(\.id)
            }) where !pending.isEmpty {
                await reachable()
                try await Task.sleep(for: .seconds(1.2))
                // 与真的 Mac 一样，说出去的话送达后记一条发送记录（任务因此进行中、关联到这个会话）
                let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { _ in }) { [quotaFails] request, _ in
                    await Task.wait(for: .seconds(1))
                    if let outcome = await DemoAgentLibrary.apply(request, store: store) { return outcome }
                    #if os(macOS)
                    if request.mode == .known(.step) {
                        do { try await AppServices.fillStep(request.content, in: store, runtimes: [:]) } catch { return .failed(ShownText(error)) }
                    }
                    #endif
                    if quotaFails, request.mode == .known(.quota) { return .failed(ShownText("这台 Mac 上没有在线的 Pi 会话")) }
                    if request.mode == .known(.send) {
                        do {
                            _ = try await store.recordSend(request.content, to: request.target, card: request.cardID, delivery: request.id, origin: request.origin)
                        } catch {
                            return .failed(ShownText(error))
                        }
                    }
                    return .succeeded
                }
                try await executor.start()
                for try await open in store.observe({ store in
                    try store.deliveryRequests().contains { pending.contains($0.id) && $0.isOpen }
                }) where !open { break }
                await executor.stop()
                // 各自演一轮，不挡住下一批话的接手
                for id in pending { Task { await running("演示 Mac 回一轮") { try await playRound(for: id, store: store, host: host) } } }
            }
        }
    }

    static func demoCueAnswers(_ store: CueStore) async throws {
        let context = try await store.cueState()?.context
        try await store.setDemoCueState(.thinking, context: context)
        try await Task.sleep(for: .seconds(4))
        _ = try await store.addCueMessage(.cue, text: String(localized: "收到，我这就去看。", table: "Demo"))
        try await store.setDemoCueState(.settled, context: context)
    }

    /// 你对运行在演示 Mac 上的 Cue 说了、还没交给它的话；演示 Mac 不在线（`-CuePadCuePresence asleep`，没写在线记录）时它收不到。
    private static func toDemoCue(_ store: isolated CueStore) throws -> [UUID] {
        guard try store.cueProfile()?.hostID == "demo-mac", try store.macOnline("demo-mac") else { return [] }
        return try store.cueMessagesToDeliver().filter { $0.author == .known(.you) }.map(\.id)
    }

    /// 会话换状态就换位置（按要你注意的先后排）：配 iOS 的 agent 与 `-CuePadProject CuePad`，列表只剩这个项目的几张卡，它不会出屏。
    static func cycleIfAsked(_ services: AppServices) async {
        guard args.driveOpts.cycle else { return }
        if !args.demoMac { Task { await runDemoMac(services) } }
        await running("状态轮播") { try await cycle(services) }
    }

    private static func cycle(_ services: AppServices) async throws {
        let store = services.store
        let query = SessionQuery(id: SessionState.recordID(sessionID: "scratch"))
        let recorder = demoRecorder(store)
        func set(_ state: WorkState, _ detail: String, question: Question? = nil) async throws {
            guard let session = try await store.sessionPage(query).items.first?.state else { return }
            try await replay(session, as: state, detail: detail, question: question, recorder: recorder)
        }
        // 说过话的会话做完一轮才是"有新回复"（刚开的还是新会话）
        try await store.writeTranscript(SessionTranscript(
            sessionID: "scratch", messages: [], recap: Recap(lastPrompt: String(localized: "先跑一遍测试", table: "Demo"), lastReply: String(localized: "全部通过。", table: "Demo"))))
        while !Task.isCancelled {
            guard let session = try await store.sessionPage(query).items.first?.state else { return }
            _ = try await store.requestDelivery(String(localized: "再跑一遍测试", table: "Demo"), to: session.target, on: session.hostID, mode: .send)
            var worked = false
            for try await state in store.observe({ try $0.sessionPage(query).items.first?.state.state }) {
                if state?.isWorking == true { worked = true } else if worked, state == .known(.settled) { break }
            }
            // 每个状态停留的时长是演示节奏，不是在等别的事
            await Task.wait(for: .seconds(2.5))
            try await set(.waitingForUser, String(localized: "要提交吗？", table: "Demo"), question: Question(promptID: "cycle", kind: .confirm, text: String(localized: "要提交吗？", table: "Demo")))
            await Task.wait(for: .seconds(3))
            try await set(.error, String(localized: "模型拒绝了请求（400）", table: "Demo"))
            await Task.wait(for: .seconds(3))
        }
    }

    private static func playRound(for request: UUID, store: CueStore, host: String) async throws {
        guard let ref = try await store.deliveryRequest(request)?.target.ref,
              let session = try await store.sessionPage(SessionQuery(id: SessionState.recordID(sessionID: ref))).items.first?.state
        else { return }
        let recorder = demoRecorder(store, host: host)
        await Task.wait(for: .seconds(0.8))
        try await replay(session, as: .thinking, recorder: recorder)
        await Task.wait(for: .seconds(2.5))
        try await replay(session, as: .settled, recorder: recorder)
    }

    /// 演示会话换一个状态：名字、所在、模型、命令与上下文照旧（记录器每次整份写入，不带上就被清掉）。
    private static func replay(
        _ session: SessionState, as state: WorkState, detail: String? = nil, question: Question? = nil, recorder: StateRecorder
    ) async throws {
        _ = try await recorder.update(
            sessionID: session.sessionID, state: state, detail: detail, title: session.title, directory: session.folder, projectID: session.projectID,
            question: question, modelState: ModelState(model: session.model, thinking: session.thinking, fast: session.fast, models: demoModels.models),
            context: session.context, commands: demoCommands, agent: session.agent.known)
    }
}
#endif
