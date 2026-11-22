#if DEBUG
import CueStore
import CueText
import Foundation
import Observation

extension DebugScene {
    private static var quotaFails: Bool {
        #if os(iOS)
        args.quotaOpts.fails
        #else
        false
        #endif
    }

    static func runDemoMac(_ services: AppServices) async {
        let store = services.store, host = "demo-mac"
        if quotaFails {
            Task {
                var answering: Set<String> = [host]
                for await hosts in Observations({ services.quotaRefreshKey }) {
                    for other in hosts where answering.insert(other).inserted {
                        let executor = DeliveryExecutor(store: store, hostID: other, onIssue: { abandon("演示 Mac 读写库", $0) }) { request, _ in
                            request.mode == .known(.quota) ? .failed(ShownText("这台 Mac 上没有在线的 Pi 会话")) : .succeeded
                        }
                        await running("演示 Mac 答额度") { try await executor.start() }
                    }
                }
            }
            holdingReady("额度明细里没查到的那一行（-CuePadQuotaFails）") {
                for await failed in Observations({ if case .failed = services.accountQuotas.phase { true } else { false } }) where failed { return }
            }
        }
        func reachable() async {
            for await offline in Observations({ services.syncing.state.status == .offline }) where !offline { return }
        }
        Task {
            await running("演示 Mac 交给 Cue") {
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
                let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { abandon("演示 Mac 读写库", $0) }) { request, _ in
                    await Task.wait(for: .seconds(1))
                    return await demoMacOutcome(request, host: host, store: store)
                }
                try await executor.start()
                for try await open in store.observe({ store in
                    try store.deliveryRequests().contains { pending.contains($0.id) && $0.isOpen }
                }) where !open { break }
                await executor.stop()
                for id in pending { Task { await running("演示 Mac 回一轮") { try await playRound(for: id, store: store, host: host) } } }
            }
        }
    }

    private static func demoMacOutcome(_ request: DeliveryRequest, host: String, store: CueStore) async -> DeliveryOutcome {
        guard let mode = request.mode.known else { return .failed(ShownText(SendError.unsupportedMode(request.mode.rawValue))) }
        do {
            switch mode {
            case .send:
                _ = try await store.recordSend(request.content, to: request.target, card: request.cardID, delivery: request.id, origin: request.origin)
            case .step:
                #if os(macOS)
                try await AppServices.fillStep(request.content, in: store, runtimes: [:])
                #endif
            case .quota:
                if quotaFails { return .failed(ShownText("这台 Mac 上没有在线的 Pi 会话")) }
            case .tidy, .libraryEdit:
                return await DemoAgentLibrary.apply(request, store: store) ?? .failed(ShownText(SendError.unsupportedMode(request.mode.rawValue)))
            case .end:
                guard let ref = request.target.ref else { break }
                try await demoRecorder(store, host: host).end(sessionID: ref, confirming: request.coveredEndRequests)
            case .withdraw, .start, .transcript, .bind, .stop, .retry, .answer, .config, .command:
                break
            }
            return .succeeded
        } catch {
            return .failed(ShownText(error))
        }
    }

    static func demoCueAnswers(_ store: CueStore) async throws {
        let context = try await store.cueState()?.context
        try await store.setDemoCueState(.thinking, context: context)
        try await Task.sleep(for: .seconds(4))
        _ = try await store.addCueMessage(.cue, text: String(localized: "收到，我这就去看。", table: "Demo"))
        try await store.setDemoCueState(.settled, context: context)
    }

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
        try await store.writeTranscript(SessionTranscript(
            sessionID: "scratch", messages: [], recap: Recap(lastPrompt: String(localized: "先跑一遍测试", table: "Demo"), lastReply: String(localized: "全部通过。", table: "Demo"))))
        while !Task.isCancelled {
            guard let session = try await store.sessionPage(query).items.first?.state else { return }
            _ = try await store.requestDelivery(String(localized: "再跑一遍测试", table: "Demo"), to: session.target, on: session.hostID, mode: .send)
            var worked = false
            for try await state in store.observe({ try $0.sessionPage(query).items.first?.state.state }) {
                if state?.isWorking == true { worked = true } else if worked, state == .known(.settled) { break }
            }
            await Task.wait(for: .seconds(2.5))
            try await set(.waitingForUser, String(localized: "要提交吗？", table: "Demo"), question: Question(promptID: "cycle", kind: .confirm, text: String(localized: "要提交吗？", table: "Demo")))
            await Task.wait(for: .seconds(3))
            try await set(.error, String(localized: "模型拒绝了请求（400）", table: "Demo"))
            await Task.wait(for: .seconds(3))
        }
    }

    private static func playRound(for request: UUID, store: CueStore, host: String) async throws {
        guard let asked = try await store.deliveryRequest(request), asked.mode != .known(.end), let ref = asked.target.ref else { return }
        let recorder = demoRecorder(store, host: host)
        for (wait, state) in [(0.8, WorkState.thinking), (2.5, .settled)] {
            await Task.wait(for: .seconds(wait))
            guard let session = try await store.sessionPage(SessionQuery(id: SessionState.recordID(sessionID: ref))).items.first?.state,
                  session.state != .known(.ended)
            else { return }
            try await replay(session, as: state, recorder: recorder)
        }
    }

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
