import CueStore
import Foundation

extension AppServices {
    /// 撤回一句说出去的话：发给会话的，还没被 Mac 领取才撤得回，明确未交出的失败按库里的当前状态撤回；
    /// 对 Cue 说的，还没交给它才撤得回。撤了立即把删除传上去，免得 Mac 先拉到它；撤不回时抛出原因。
    func withdraw(_ said: Said) async throws {
        guard said.trip(at: speech).unconfirmedReason == nil else { throw SendError.alreadyHanded }
        switch said {
        case .request(let request) where request.status == .known(.failed):
            guard try await store.withdrawFailedDelivery(request.id) else { throw SendError.alreadyHanded }
        case .request(let request):
            if try await !store.withdrawDelivery(request.id, locallyOn: speech.localHost) {
                guard request.status == .known(.preparing) else { throw SendError.alreadyHanded }
                try await withdrawRemotely(request.id)
                try await store.deleteDelivery(request.id)
            }
        case .cue(let message, _):
            guard try await store.withdrawCueMessage(message.id) else { throw SendError.alreadyHeard }
        }
        Task { await upload(said.id, deleted: true) }
    }

    private func withdrawRemotely(_ id: UUID) async throws {
        let deadline = timing.now().addingTimeInterval(Speech.receiptLimit)
        guard let withdrawal = try await store.requestDeliveryWithdrawal(id) else { throw SendError.alreadyHanded }
        let request = uploaded(withdrawal)
        let result = try await withThrowingTaskGroup(of: DeliveryRequest.self) { [store, timing] group in
            group.addTask { try await store.outcome(of: request) }
            group.addTask {
                try await timing.sleepUntil(deadline)
                throw SendError.alreadyHanded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard result.status == .known(.succeeded) else { throw SendError.alreadyHanded }
    }

    /// Mac 本机也走投送通道、由执行器交给扩展；写出后立即上传（不等它完成），结果用 `CueStore.outcome(of:)` 等。
    func uploaded(_ request: DeliveryRequest) -> DeliveryRequest {
        Task { await upload(request.id) }
        return request
    }

    /// 马上传这几条，同一次写入写出的一起给。
    func upload(_ records: UUID..., deleted: Bool = false) async {
        await sync?.upload(records, deleted: deleted)
    }

    /// 问题不能从这里作答时抛 `SendError.unanswerable`。
    func answer(_ value: PiAnswerValue, to session: PiSessionState) async throws -> DeliveryRequest {
        guard let question = session.question, question.isAnswerable, let promptID = question.promptID else {
            throw SendError.unanswerable
        }
        return uploaded(try await store.requestAnswer(
            PiAnswer(promptID: promptID, value: value, question: question.text), to: session.target,
            on: session.hostID))
    }

    func configure(_ config: PiConfig, for session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestConfig(config, to: session.target, on: session.hostID))
    }

    /// 新名为空时抛 `CueStoreError.blankDeliveryContent`。
    @discardableResult
    func rename(_ session: PiSessionState, to name: String) async throws -> DeliveryRequest {
        guard let name = PiRename.clean(name) else { throw CueStoreError.blankDeliveryContent }
        return try await configure(PiConfig(name: name), for: session)
    }

    /// 会话记录与对话都留着，之后再给它发消息会在后台恢复；已经结束的会话也算成功。
    func end(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestEnd(of: session.target, on: session.hostID))
    }

    /// 只停指挥官自己这一轮，子代理照常跑；已经结束或空闲的会话也算成功。
    func stop(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestStop(of: session.target, on: session.hostID))
    }

    /// 不补发用户消息；还在路上时再点不会再发一条（Store 去重）。
    func retry(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestRetry(of: session.target, on: session.hostID))
    }

    /// `model`、`thinking` 为 nil 是这家的默认。这里生成这一次的认领标识：同步记录上出现带同一个 `launchToken` 的会话就是它（`SessionLaunch`）。
    /// `card`：从这条灵感或任务开的，开好后它关联到新会话、会话名按它定。
    /// `intent`：首次、安全替换或确认后重复，由 Store 在事务里按任务已有请求核对。
    func launchSession(
        in project: UUID, prompt: String?, title: String, on host: String, card: UUID?, agent: AgentKind,
        model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, fast: Bool = false, intent: SessionLaunchIntent = .new
    ) async throws -> SessionLaunch {
        let token = UUID().uuidString
        let request = uploaded(try await store.requestLaunch(
            PiLaunch(project: project, prompt: prompt, token: token, agent: agent, model: model, thinking: thinking, fast: fast),
            title: title, on: host, card: card, intent: intent))
        if case .replacing(let previous) = intent { Task { await upload(previous, deleted: true) } }
        return SessionLaunch(request: request.id, token: token)
    }

    /// `PiBind.folder` 为 nil 是解除；手机没有完整路径，由那台 Mac 解析并写本机的目录绑定。
    func requestBind(_ bind: PiBind, title: String, on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestBind(bind, title: title, on: host))
    }

    func requestTidy(_ orders: [TidyOrder], on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestTidy(orders, on: host))
    }

    func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestLibraryEdit(edit, title: title, on: host))
    }

    func requestTranscript(of session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestTranscript(of: session))
    }
}

nonisolated extension PiSessionState {
    var target: SendTarget { SendTarget(kind: .piSession, name: title, ref: sessionID) }
}
