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
        @MainActor @Sendable func reachable() async {
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
            let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { abandon("演示 Mac 读写库", $0) }) { request, _ in
                await reachable()
                await Task.wait(for: .seconds(2.2))
                let outcome = await demoMacOutcome(request, host: host, store: store)
                if case .succeeded = outcome { Task { await running("演示 Mac 回一轮") { try await playRound(for: request.id, store: store, host: host) } } }
                return outcome
            }
            try await executor.start()
            for await _ in AsyncStream<Void>.makeStream().stream {}
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

    /// 送达后回一轮。画面摆好后才发出的（按发送钮、手打的）像真的 Agent 那样：这句落进会话、想一下、跑几步工具（中间说一句）、回答落下、歇下；
    /// 演示预置的只想一下就歇（`preparedAt`），不往别的会话里写对话。
    private static func playRound(for request: UUID, store: CueStore, host: String) async throws {
        guard let asked = try await store.deliveryRequest(request), asked.mode != .known(.end), let ref = asked.target.ref else { return }
        let recorder = demoRecorder(store, host: host, minInterval: .zero)
        func current() async throws -> SessionState? {
            try await store.sessionPage(SessionQuery(id: SessionState.recordID(sessionID: ref))).items.first.map(\.state).flatMap { $0.state == .known(.ended) ? nil : $0 }
        }
        guard let prepared = preparedAt, asked.createdAt > prepared else {
            for (wait, state) in [(0.8, WorkState.thinking), (2.5, .settled)] {
                await Task.wait(for: .seconds(wait))
                guard let session = try await current() else { return }
                try await replay(session, as: state, recorder: recorder)
            }
            return
        }
        let seq = Int64(3_000_000 + Int(Date.now.timeIntervalSinceReferenceDate) % 1_000_000 * 2)
        let you = ChatMessage(sessionID: ref, entryID: "demo-u\(request)", seq: seq, role: .user, text: asked.content, at: .now, deliveryID: request)
        await Task.wait(for: .seconds(0.6))
        guard let session = try await current() else { return }
        try await store.writeTranscript(SessionTranscript(sessionID: ref, messages: [you], recap: Recap(pendingPrompt: you.text)))
        try await replay(session, as: .thinking, recorder: recorder)
        var tools = ChatMessage.Tools()
        let steps: [(WorkState, ChatMessage.Tools.Item?, String?, Double)] = [
            (.thinking, nil, nil, 1.6),
            (.tool, .init(kind: .read, target: "Sources/Scheduler/Queue.swift"), "read · Queue.swift", 1.2),
            (.tool, .init(kind: .search, target: "firstJoinedAt"), "grep · firstJoinedAt", 1.0),
            (.thinking, .init(kind: .said, target: String(localized: "排序用的是重连时的时间戳，改成首次加入时间。", table: "Demo")), nil, 1.4),
            (.tool, .init(kind: .edit, target: "Sources/Scheduler/Queue.swift", added: 3, removed: 2), "edit · Queue.swift", 1.2),
            (.tool, .init(kind: .command, target: "swift test --filter Reconnect"), "bash · swift test --filter Reconnect", 2.0),
            (.thinking, nil, nil, 1.2),
        ]
        for (state, item, detail, wait) in steps {
            guard let session = try await current() else { return }
            if let item {
                tools.record(item)
                try await store.writeTranscript(SessionTranscript(sessionID: ref, messages: [], recap: Recap(pendingPrompt: you.text, pendingTools: tools)))
            }
            try await replay(session, as: state, detail: detail, recorder: recorder)
            await Task.wait(for: .seconds(wait))
        }
        guard let session = try await current() else { return }
        let reply = String(localized: "改好了：队列按首次加入时间排序，重连的人不再插到最前。\n\n`swift test --filter Reconnect` 4 个用例全部通过，压测里 p95 从 12ms 降到 9ms。", table: "Demo")
        let answer = ChatMessage(sessionID: ref, entryID: "demo-p\(request)", seq: seq + 1, role: .pi, text: reply, at: .now, tools: tools, roundStartedAt: you.at)
        try await store.writeTranscript(SessionTranscript(sessionID: ref, messages: [answer], recap: Recap(lastPrompt: you.text, lastReply: reply, answeredAt: .now)))
        try await replay(session, as: .settled, recorder: recorder)
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
