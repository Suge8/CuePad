import CueStore
import Foundation

extension AppServices {
    /// 撤回一句说出去的话：发给会话的，还没被 Mac 领取才撤得回，明确未交出的失败按库里的当前状态撤回；
    /// 对 Cue 说的，还没交给它才撤得回（删除由同步层马上传，免得 Mac 先拉到它）；撤不回时抛出原因。
    func withdraw(_ said: Said) async throws {
        guard said.trip(at: speech).unconfirmedReason == nil else { throw SendError.alreadyHanded }
        switch said {
        case .request(let request) where request.status == .known(.failed):
            guard try await store.withdrawFailedDelivery(request.id) else { throw SendError.alreadyHanded }
        case .request(let request):
            if try await !store.withdrawDelivery(request.id, locallyOn: speech.localHost) {
                guard request.status == .known(.preparing) else { throw SendError.alreadyHanded }
                try await withdrawRemotely(request.id, on: request.hostID)
                try await store.deleteDelivery(request.id)
            }
        case .cue(let message, _):
            guard try await store.withdrawCueMessage(message.id) else { throw SendError.alreadyHeard }
        }
    }

    private func withdrawRemotely(_ id: UUID, on host: String) async throws {
        let result = try await awaitOutcome(onTimeout: SendError.alreadyHanded) {
            try await request(on: host) {
                guard let withdrawal = try await store.requestDeliveryWithdrawal(id) else { throw SendError.alreadyHanded }
                return withdrawal
            }
        }
        guard result.status == .known(.succeeded) else { throw SendError.alreadyHanded }
    }

    /// 写出请求、等那台办完；从写之前起 `Speech.receiptLimit` 内没结果抛 `onTimeout`。
    func awaitOutcome(onTimeout: SendError, _ write: () async throws -> DeliveryRequest) async throws -> DeliveryRequest {
        let deadline = timing.now().addingTimeInterval(Speech.receiptLimit)
        let request = try await write()
        return try await withThrowingTaskGroup(of: DeliveryRequest.self) { [store, timing] group in
            group.addTask { try await store.outcome(of: request) }
            group.addTask {
                try await timing.sleepUntil(deadline)
                throw onTimeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// 你要一台 Mac 做的事（说话、停下、结束、开会话、回答、改设置……）都经这里写成请求（同步层马上传，`Table.urgent`）。
    /// 那台说了离开、还没回来（`CueStore.macKnownOff`）时不写、抛 `SendError.macOff`：写了没人领，到派发期限才作废，这之前界面只能说"已发出"。
    /// 任务收尾顺带的结束（`CueStore.endUnusedSessions`）不经这里：那是库里推出来的，界面不显示它在路上，那台回来同步到这件事收尾时自己也会写。
    func request(on host: String, _ write: () async throws -> DeliveryRequest) async throws -> DeliveryRequest {
        try await requireAwake(host)
        return try await write()
    }

    /// 手里那条"离开"可能已经过时（它回来了，本机刚回前台还没拉到）：说它没开之前先拉一次再看。拉不通就是同步不通，说不准，照常排着。
    func requireAwake(_ host: String) async throws {
        guard try await store.macKnownOff(host, at: speech) != nil else { return }
        await syncNow()
        if let mac = try await store.macKnownOff(host, at: speech) { throw SendError.macOff(mac) }
    }

    /// 问题不能从这里作答时抛 `SendError.unanswerable`。
    func answer(_ value: AnswerValue, to session: SessionState) async throws -> DeliveryRequest {
        guard let question = session.question, question.isAnswerable, let promptID = question.promptID else {
            throw SendError.unanswerable
        }
        return try await request(on: session.hostID) {
            try await store.requestAnswer(Answer(promptID: promptID, value: value, question: question.text), to: session.target, on: session.hostID)
        }
    }

    func configure(_ config: SessionConfig, for session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestConfig(config, to: session.target, on: session.hostID) }
    }

    /// 新名为空时抛 `CueStoreError.blankDeliveryContent`。
    @discardableResult
    func rename(_ session: SessionState, to name: String) async throws -> DeliveryRequest {
        guard let name = SessionRename.clean(name) else { throw CueStoreError.blankDeliveryContent }
        return try await configure(SessionConfig(name: name), for: session)
    }

    /// 会话记录与对话都留着，之后再给它发消息会在后台恢复；已经结束的会话也算成功。
    func end(_ session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestEnd(of: session.target, on: session.hostID) }
    }

    /// 只停指挥官自己这一轮，子代理照常跑；已经结束或空闲的会话也算成功。
    func stop(_ session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestStop(of: session.target, on: session.hostID) }
    }

    /// 不补发用户消息；还在路上时再点不会再发一条（Store 去重）。
    func retry(_ session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestRetry(of: session.target, on: session.hostID) }
    }

    /// `model`、`thinking` 为 nil 是这家的默认。这里生成这一次的认领标识：同步记录上出现带同一个 `launchToken` 的会话就是它（`SessionLaunch`）。
    /// `card`：从这条灵感或任务开的，开好后它关联到新会话、会话名按它定。
    /// `intent`：首次、安全替换或确认后重复，由 Store 在事务里按任务已有请求核对。
    func launchSession(
        in project: UUID, prompt: String?, title: String, on host: String, card: UUID?, agent: AgentKind,
        model: ModelKey? = nil, thinking: ThinkingLevel? = nil, fast: Bool = false, intent: SessionLaunchIntent = .new
    ) async throws -> SessionLaunch {
        let token = UUID().uuidString
        let request = try await request(on: host) {
            try await store.requestLaunch(
                LaunchRequest(project: project, prompt: prompt, token: token, agent: agent, model: model, thinking: thinking, fast: fast),
                title: title, on: host, card: card, intent: intent)
        }
        return SessionLaunch(request: request.id, token: token)
    }

    /// `BindRequest.folder` 为 nil 是解除；手机没有完整路径，由那台 Mac 解析并写本机的目录绑定。
    func requestBind(_ bind: BindRequest, title: String, on host: String) async throws -> DeliveryRequest {
        try await request(on: host) { try await store.requestBind(bind, title: title, on: host) }
    }

    func requestTidy(_ orders: [TidyOrder], on host: String) async throws -> DeliveryRequest {
        try await request(on: host) { try await store.requestTidy(orders, on: host) }
    }

    func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) async throws -> DeliveryRequest {
        try await request(on: host) { try await store.requestLibraryEdit(edit, title: title, on: host) }
    }

    func requestTranscript(of session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestTranscript(of: session) }
    }
}

nonisolated extension SessionState {
    var target: SendTarget { SendTarget(kind: .piSession, name: title, ref: sessionID) }
}
