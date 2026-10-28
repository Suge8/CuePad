import CueStore
import Foundation

extension AppServices {
    /// 撤回一句说出去的话（重发或移除没能送达的话）：发给会话的，还没被 Mac 领取的才撤得回，没能送达的直接删；
    /// 对 Cue 说的，还没交给它的才撤得回。撤了立即把删除传上去，免得 Mac 先拉到它；撤不回时抛出原因。
    func withdraw(_ said: Said) async throws {
        switch said {
        case .request(let request) where request.status == .known(.failed):
            try await store.deleteDelivery(request.id)
        case .request(let request):
            guard try await store.withdrawDelivery(request.id) else { throw SendError.alreadyHanded }
        case .cue(let message, _):
            guard try await store.withdrawCueMessage(message.id) else { throw SendError.alreadyHeard }
        }
        Task { await upload(said.id, deleted: true) }
    }

    /// 投送请求（发送、作答、配置、结束、停止、重跑、开会话、绑定、补对话）都走同一条投送通道，Mac 本机也走它、由执行器交给扩展；
    /// 写出后立即上传（不等它完成），结果用 `CueStore.outcome(of:)` 等。
    func uploaded(_ request: DeliveryRequest) -> DeliveryRequest {
        Task { await upload(request.id) }
        return request
    }

    /// 马上传这几条（`SyncControlling.upload`，同一次写入写出的一起给）：手机写出投送请求、Mac 写回结果、Mac 写出带通知标志的会话状态后都调用。
    /// 没有同步时什么也不做。
    func upload(_ records: UUID..., deleted: Bool = false) async {
        await sync?.upload(records, deleted: deleted)
    }

    /// 回答会话正在等的弹窗：写一条作答请求给会话所在的 Mac。
    /// 问题不能从这里作答（没有标识或种类不认识）时抛 `SendError.unanswerable`。
    func answer(_ value: PiAnswerValue, to session: PiSessionState) async throws -> DeliveryRequest {
        guard let question = session.question, question.isAnswerable, let promptID = question.promptID else {
            throw SendError.unanswerable
        }
        return uploaded(try await store.requestAnswer(
            PiAnswer(promptID: promptID, value: value, question: question.text), to: session.target,
            on: session.hostID))
    }

    /// 换会话的模型或思考强度：当前值与可选项读会话状态的 `model`、`thinking`、`models`。
    func configure(_ config: PiConfig, for session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestConfig(config, to: session.target, on: session.hostID))
    }

    /// 结束会话：请会话所在的 Mac 让它的 Pi 进程正常退出。会话记录与对话都留着，之后再给它发消息会在后台恢复；已经结束的会话也算成功。
    func end(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestEnd(of: session.target, on: session.hostID))
    }

    /// 停止这一轮：请会话所在的 Mac 中止它正在跑的回合（相当于在 Pi 里按 Esc）。会话随后回到等你下一句（状态记录里是"完成"，被中止）；
    /// 只停指挥官自己这一轮，子代理照常跑；已经结束或空闲的会话也算成功。界面只在会话 `state.isTurnRunning` 时给入口（等子代理时指挥官没有在跑的一轮）。
    func stop(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestStop(of: session.target, on: session.hostID))
    }

    /// 把出错的那一轮原样重跑一遍（`PiSessionState.canRetry`）：请会话所在的 Mac 让扩展重跑它，对话里不多一句话，只多出新的回答；
    /// 还在路上时再点不会再发一条（Store 去重）。会话的显示状态按这条请求当场是"在路上"（`PiDelivery`）。
    func retry(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestRetry(of: session.target, on: session.hostID))
    }

    /// 请 `host` 那台 Mac 在项目的文件夹里用 `agent` 开新会话（`model`、`thinking` 为 nil 是这家的默认），`prompt` 作开场。
    /// `title` 是给人看的目标名（会话名或项目名）。这里生成这一次的认领标识：同步记录上出现带同一个 `launchToken` 的会话就是它（`SessionLaunch`）。
    /// `card`：从这条灵感或任务开的（开好后它关联到新会话、会话名按它定，见 `CueStore.requestLaunch`、`CueStore.claimLaunchedCards`）。
    func launchSession(
        in project: UUID, prompt: String?, title: String, on host: String, card: UUID?, agent: AgentKind,
        model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil
    ) async throws -> SessionLaunch {
        let token = UUID().uuidString
        let request = uploaded(try await store.requestLaunch(
            PiLaunch(project: project, prompt: prompt, token: token, agent: agent, model: model, thinking: thinking), title: title, on: host, card: card))
        return SessionLaunch(request: request.id, token: token)
    }

    /// 请 `host` 那台 Mac 给项目绑定文件夹（`PiBind.folder` 为 nil 是解除；手机没有完整路径，由那台 Mac 解析并写本机的目录绑定）；
    /// 绑好后目录绑定记录随同步回来。
    func requestBind(_ bind: PiBind, title: String, on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestBind(bind, title: title, on: host))
    }

    /// 请 `host` 那台 Mac 整理技能与规则（`Workspace.tidy`）。
    func requestTidy(_ orders: [TidyOrder], on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestTidy(orders, on: host))
    }

    /// 请 `host` 那台 Mac 改一份技能或规则文件（`Workspace.saveFile`）。
    func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestLibraryEdit(edit, title: title, on: host))
    }

    /// 请会话所在的 Mac 把这个会话的对话补写进来（7 天前活跃过、还没有对话的会话打开时调用）。
    func requestTranscript(of session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestTranscript(of: session))
    }
}

nonisolated extension PiSessionState {
    /// 投送请求里指这个会话的目标（`ref` 是 Pi 自己的会话 id）。
    var target: SendTarget { SendTarget(kind: .piSession, name: title, ref: sessionID) }
}
