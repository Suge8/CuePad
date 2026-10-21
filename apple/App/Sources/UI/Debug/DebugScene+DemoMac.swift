#if DEBUG
import CueStore
import CueText
import Foundation
import Observation

extension DebugScene {
    static func runDemoMac(_ services: AppServices) async {
        let store = services.store, host = "demo-mac"
        func reachable() async {
            for await offline in Observations({ services.syncStatus == .offline }) where !offline { return }
        }
        Task {
            do {
                // 每次变化都重读此刻还没交出去的：攒下的旧变化不再各等一遍
                for try await waiting in store.observe({ try toDemoCue($0) }) where !waiting.isEmpty {
                    guard try await !toDemoCue(store).isEmpty else { continue }
                    await reachable()
                    try await Task.sleep(for: .seconds(1.5))
                    try await store.markCueMessagesDelivered(toDemoCue(store))
                    try await demoCueAnswers(store)
                }
            } catch {
                demoLog.error("演示 Mac 交给 Cue 停了：\(error)")
            }
        }
        do {
            for try await pending in store.observe({ store in
                try store.deliveryRequests().filter { $0.hostID == host && $0.status == .known(.pending) }.map(\.id)
            }) where !pending.isEmpty {
                await reachable()
                try await Task.sleep(for: .seconds(1.2))
                // 与真的 Mac 一样，说出去的话送达后记一条发送记录（任务因此进行中、关联到这个会话）
                let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { _ in }) { request in
                    try? await Task.sleep(for: .seconds(1))
                    if let mode = request.mode.known, DeliveryMode.toSession.contains(mode), mode != .answer {
                        _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID, delivery: request.id, origin: request.origin)
                    }
                    return .succeeded
                }
                try await executor.start()
                for try await open in store.observe({ store in
                    try store.deliveryRequests().contains { pending.contains($0.id) && $0.isOpen }
                }) where !open { break }
                await executor.stop()
                // 各自演一轮，不挡住下一批话的接手
                for id in pending { Task { await playRound(for: id, store: store, host: host) } }
            }
        } catch is CancellationError {
        } catch {
            demoLog.error("演示 Mac 接手停了：\(error)")
        }
    }

    /// 演示 Mac 上的 Cue 接到你的话：思考几秒再回一句（同值班的 Mac 写下的样子，上下文照旧），看发出后的"思考中"与回答落下。
    static func demoCueAnswers(_ store: CueStore) async throws {
        let context = try await store.cueState()?.context
        try await store.setCueState(.thinking, context: context)
        try await Task.sleep(for: .seconds(4))
        _ = try await store.addCueMessage(.cue, text: "收到，我这就去看。")
        try await store.setCueState(.settled, context: context)
    }

    /// 你对运行在演示 Mac 上的 Cue 说了、还没交给它的话；演示 Mac 不在线（`-CuePadCuePresence asleep`，没写在线记录）时它收不到。
    private static func toDemoCue(_ store: isolated CueStore) throws -> [UUID] {
        guard try store.cueProfile()?.hostID == "demo-mac", try store.macOnline("demo-mac") else { return [] }
        return try store.cueMessagesToDeliver().filter { $0.author == .known(.you) }.map(\.id)
    }

    /// `-CuePadCycle YES`（配 `-CuePadDemo YES`，画面就绪后开始、一直循环）：scratch 一个会话依次走过各种状态，录状态切换的动效用（`xc.sh rec`）——
    /// 发出一句（发送中，演示 Mac 接手，见 `runDemoMac`）→ 思考中 → 做完（有新回复）→ 等你确认 → 出错，再从发出一句开始。
    /// 会话换状态就换位置（按要你注意的先后排）：配 iOS 的 agent 与 `-CuePadProject CuePad`，列表只剩这个项目的几张卡，它不会出屏。
    static func cycleIfAsked(_ services: AppServices) async {
        guard defaults.bool(forKey: "CuePadCycle") else { return }
        let store = services.store
        if !defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(services) } }
        let query = PiSessionQuery(id: PiSessionState.recordID(sessionID: "scratch"))
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        func set(_ state: PiWorkState, _ detail: String, question: PiQuestion? = nil) async {
            guard let session = try? await store.piSessionPage(query).items.first?.state else { return }
            await replay(session, as: state, detail: detail, question: question, recorder: recorder)
        }
        // 说过话的会话做完一轮才是"有新回复"（刚开的还是新会话）
        try? await store.writePiTranscript(PiTranscript(
            sessionID: "scratch", messages: [], recap: PiRecap(lastPrompt: "先跑一遍测试", lastReply: "全部通过。")))
        while !Task.isCancelled {
            guard let session = try? await store.piSessionPage(query).items.first?.state,
                  (try? await store.requestDelivery("再跑一遍测试", to: session.target, on: session.hostID, mode: .send)) != nil else { return }
            // 等演示 Mac 走完这一轮：干过活、又歇下
            var worked = false
            do {
                for try await state in store.observe({ try $0.piSessionPage(query).items.first?.state.state }) {
                    if state?.isWorking == true { worked = true } else if worked, state == .known(.settled) { break }
                }
            } catch { return }
            // 每个状态停留的时长是演示节奏，不是在等别的事
            try? await Task.sleep(for: .seconds(2.5))
            await set(.waitingForUser, "要提交吗？", question: PiQuestion(promptID: "cycle", kind: .confirm, text: "要提交吗？"))
            try? await Task.sleep(for: .seconds(3))
            await set(.error, "模型拒绝了请求（400）")
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// 会话状态晚于送达结果同步过来：先进入思考，过一会儿做完。
    private static func playRound(for request: UUID, store: CueStore, host: String) async {
        guard let ref = try? await store.deliveryRequest(request)?.target.ref,
              let session = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: ref))).items.first?.state
        else { return }
        let recorder = PiStateRecorder(store: store, hostID: host)
        try? await Task.sleep(for: .seconds(0.8))
        await replay(session, as: .thinking, recorder: recorder)
        try? await Task.sleep(for: .seconds(2.5))
        await replay(session, as: .settled, recorder: recorder)
    }

    /// 演示会话换一个状态：名字、所在、模型、命令与上下文照旧（记录器每次整份写入，不带上就被清掉）。
    private static func replay(
        _ session: PiSessionState, as state: PiWorkState, detail: String? = nil, question: PiQuestion? = nil, recorder: PiStateRecorder
    ) async {
        _ = try? await recorder.update(
            sessionID: session.sessionID, state: state, detail: detail, title: session.title, directory: session.folder, projectID: session.projectID,
            question: question, modelState: PiModelState(model: session.model, thinking: session.thinking, models: demoModels.models),
            context: session.context, commands: demoCommands, agent: session.agent.known)
    }
}
#endif
