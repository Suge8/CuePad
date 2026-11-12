#if os(macOS)
import CueBridge
import CueStore
import Foundation

/// 全 App 经桥给 Agent 会话发消息，经各 Agent 的接入在后台开会话、接着会话的只有这里；成功送出的话记发送记录。
final class MacExecutor {
    let store: CueStore
    let bridge: Bridge
    private let runtimes: [AgentKind: any AgentRuntime]
    let hostID: String
    private let workspaces: Workspaces
    let recorder: StateRecorder
    private let library: AgentLibraryKeeper
    private let upload: @Sendable (UUID) async -> Void
    private let fetchFile: FileFetching
    private let refreshQuota: AccountQuotas.Query
    private let reportIssue: @MainActor (String) -> Void
    private var running: DeliveryExecutor?

    init(
        store: CueStore, bridge: Bridge, runtimes: [AgentKind: any AgentRuntime], hostID: String, workspaces: Workspaces, recorder: StateRecorder,
        library: AgentLibraryKeeper, upload: @escaping @Sendable (UUID) async -> Void, fetchFile: @escaping FileFetching,
        refreshQuota: @escaping AccountQuotas.Query,
        reportIssue: @escaping @MainActor (String) -> Void
    ) {
        self.store = store
        self.bridge = bridge
        self.runtimes = runtimes
        self.hostID = hostID
        self.workspaces = workspaces
        self.recorder = recorder
        self.library = library
        self.upload = upload
        self.fetchFile = fetchFile
        self.refreshQuota = refreshQuota
        self.reportIssue = reportIssue
    }

    func start() async throws {
        guard running == nil else { return }
        let executor = DeliveryExecutor(store: store, hostID: hostID, timing: store.timing, onIssue: { [reportIssue] error in
            let message = String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)")
            Task { @MainActor in reportIssue(message) }
        }, onWritten: upload, fetchFile: { [fetchFile] key in _ = try await fetchFile(key) }, recover: { [store, bridge, hostID] request in
            if request.mode == .known(.withdraw) {
                do { return try await store.completeDeliveryWithdrawal(request, on: hostID, refused: ShownText(SendError.alreadyHanded)) }
                catch { return .unconfirmed(ShownText(error)) }
            }
            return await DeliveryConfirmation(store: store, bridge: bridge).recover(request)
        }, preparation: { [bridge] request in
            await MacDeliveryPreparation(bridge: bridge).current(request)
        }) { [weak self] request, access in
            guard let self else { return .failed(ShownText("这台 Mac 上的 CuePad 正在退出")) }
            return await self.run(request, access: access)
        }
        running = executor
        do { try await executor.start() }
        catch { running = nil; throw error }
    }

    /// 立即不再领取新请求；返回的等待不在主线程上，退出收尾里限时等。
    func beginStop() -> @Sendable () async -> Void {
        let executor = running
        running = nil
        return { await executor?.stop() }
    }

    /// 每个意图只尝试一次。明确的前置拒绝可报失败，交出后的超时、断线或执行错误保留未知。
    private func run(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async -> DeliveryOutcome {
        do {
            guard try await store.mayBeginDelivery(request.id) else { return .failed(DeliveryPreparation.abandoned) }
            return try await perform(request, access: access)
        } catch {
            AppServices.log.error("投送请求 \(request.id, privacy: .public) \(request.mode.rawValue, privacy: .public) 没成：\(String(describing: error), privacy: .public)")
            if request.mode == .known(.start), error as? PiHostError == .notConnected { return .unconfirmed(ShownText(error)) }
            return DeliveryRefusal.definitelyNotHanded(error) ? .failed(ShownText(error)) : .unconfirmed(ShownText(error))
        }
    }

    /// 不认识的方式 `DeliveryExecutor` 已按失败写回，走到这里的都是已知方式。
    private func perform(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws -> DeliveryOutcome {
        guard let mode = request.mode.known else { throw SendError.unsupportedMode(request.mode.rawValue) }
        switch mode {
        case .withdraw:
            return try await store.completeDeliveryWithdrawal(request, on: hostID, refused: ShownText(SendError.alreadyHanded))
        case .start: return try await startSession(request)
        case .transcript: try await writeTranscript(of: request.content)
        case .step: try await AppServices.fillStep(request.content, in: store)
        case .bind: try await bindFolder(request)
        case .quota: if let failure = await refreshQuota() { return .failed(failure) }
        case .end: try await end(request)
        case .stop: try await stop(request.target)
        case .stopTurn: try await stopTurn(request)
        case .retry: try await retry(request.target)
        case .answer: try await answer(request, access: access)
        case .config: try await configure(request, access: access)
        case .command: try await runCommand(request, access: access)
        case .send: return try await deliver(request, access: access)
        case .tidy:
            guard let orders = request.tidyOrders else { throw SendError.unsupportedMode(request.mode.rawValue) }
            // 别的设备发来的整理不留撤销：撤销只给在这台上点的那一下（发的那台在按钮旁写明撤不回，`TidyConsequence`）
            _ = try await library.tidy(orders)
        case .libraryEdit:
            guard let edit = request.libraryEdit else { throw SendError.unsupportedMode(request.mode.rawValue) }
            try await library.write(edit)
        }
        return .succeeded
    }


    /// 会话在跑就由桥先打断这一轮（忙不忙以此刻为准，写请求时看到的"歇着"可能已过时）。
    /// 送出后记发送记录，带上请求 id，扩展写进会话文件的那条消息据此与请求气泡对上。
    private func deliver(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws -> DeliveryOutcome {
        let (_, id, resumed) = try await connect(request.target, access: access)
        guard let session = bridge.session(id: id) else { throw BridgeError.unknownSession(id) }
        do {
            let result = try await send(request.content, of: request, to: session)
            return resumed ? DeliveryRefusal.afterStarting(result) : result
        } catch {
            if resumed { return .unconfirmed(ShownText(error)) }
            throw error
        }
    }

    private func send(_ content: String, of request: DeliveryRequest, to session: CueBridge.Session) async throws -> DeliveryOutcome {
        var outgoing = try DeliveryMessage.make(content, request: request, session: session, files: store.files)
        if request.isFromCue {
            let context = try await store.cueSendContext(in: session.sessionID)
            outgoing.policy = .cue(deliveryID: context.deliveryID?.uuidString, turnStartedAt: context.turnStartedAt)
        }
        guard try await store.mayBeginDelivery(request.id) else { return .failed(DeliveryPreparation.abandoned) }
        try Task.checkCancellation()
        do { try await bridge.send(outgoing, to: session.id) }
        catch {
            guard session.agent == .pi, !DeliveryRefusal.definitelyNotHanded(error) else { throw error }
            return DeliveryConfirmation(store: store, bridge: bridge).pending(in: session, reason: ShownText(error))
        }
        do {
            try await store.linkDeliveredCard(request, toSession: session.sessionID)
        } catch {
            reportIssue(String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)"))
        }
        // 其余接入沿用各自的受理合同，不抹掉已有能力。
        guard !session.confirmsFromHistory else {
            return DeliveryConfirmation(store: store, bridge: bridge).pending(in: session)
        }
        await record(content, of: request, to: session.sendTarget)
        return .succeeded
    }

    /// 记发送记录。话已经送达，记不下也照样按成功写回（手机才不会重发）：没记下是这台 Mac 的资料库问题，在这里报。
    private func record(_ content: String, of request: DeliveryRequest, to target: SendTarget) async {
        guard request.mode.known?.landsAsMessage == true else { return }
        do {
            try await store.recordDelivery(request, content: content, to: target)
        } catch {
            reportIssue(String(localized: "处理投送请求时读写资料库失败：发送已完成，但没能记下这次发送：\(error.localizedDescription)"))
        }
    }

    /// 作答、改会话设置与斜杠命令交给扩展，不是发出去的内容，不记发送记录。
    /// 会话已结束时与发消息一样先在后台恢复：改名对已结束的会话也要能做，Pi 只在活着的进程里写会话名。
    private func answer(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws {
        guard let answer = request.answer else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新答案
        let (_, id, _) = try await connect(request.target, access: access)
        try await bridge.answer(answer.value, to: answer.promptID, in: id)
    }

    private func configure(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws {
        guard let config = request.config else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新强度，或什么都不改
        let (_, id, _) = try await connect(request.target, access: access)
        try await bridge.configure(config, in: id)
    }

    /// 命令带着卡片（发给 Agent 时卡片文字是参数）：卡片关联到会话，但不写发送记录。命令只有文字，带着的图片同文件一样写成路径。
    private func runCommand(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws {
        let content = SendContent(stored: request.content)
        let (ref, id, _) = try await connect(request.target, access: access)
        let line = try content.agentText(from: store.files, imagesAsFiles: true).trimmingCharacters(in: .whitespacesAndNewlines)
        try await bridge.command(line, deliveryID: request.id.uuidString, in: id)
        do { try await store.linkDeliveredCard(request, toSession: ref) } catch {
            reportIssue(String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)"))
        }
    }

    private func connect(_ target: SendTarget, access: DeliveryAdmission.Access) async throws -> (sessionID: String, id: CueBridge.Session.ID, resumed: Bool) {
        let ref = try sessionID(of: target)
        if let live = bridge.session(sessionID: ref) { return (ref, live.id, false) }
        if case .existingOnly = access { throw BridgeError.sessionEnded }
        guard let indexed = try await store.indexedSession(ref) else { throw SendError.sessionNotOnThisMac(target.name) }
        try requireDirectory(URL(filePath: indexed.cwd, directoryHint: .isDirectory))
        try Task.checkCancellation()
        return (ref, try await runtime(indexed.agent).resume(indexed), true)
    }

    /// 本版本不认识的 Agent 当作没装。
    private func runtime(_ agent: AgentKind) throws -> any AgentRuntime {
        guard let runtime = runtimes[agent] else { throw AgentRuntimeError.notInstalled(agent) }
        return runtime
    }

    // MARK: 不指向某个会话的请求（除开新会话的开场白外不写发送记录）

    /// 目录由本机按项目绑定的文件夹解析；这台 Mac 上还没绑的，先建好工作区并绑定（`workspace(of:)`）。
    /// 模型、思考强度是 Pi 的启动参数，一步生效：模型无效时 Pi 起不来，请求整体失败、不留会话。
    /// 开场的话带着这条请求的 id（对话据此认出它），并记发送记录（同 `deliver`：请求清理后对话仍认得出是谁说的）。
    private func startSession(_ request: DeliveryRequest) async throws -> DeliveryOutcome {
        guard let launch = request.launch else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
        let directory = try await workspace(of: launch.project)
        try requireDirectory(directory)
        let clock = ContinuousClock(), began = clock.now
        let id = try await runtime(launch.opening).open(
            in: directory, launchToken: launch.token, name: launch.name, model: launch.model, thinking: launch.thinking)
        if launch.fast || bridge.session(id: id)?.fast == true {
            do { try await bridge.configure(SessionConfig(fast: launch.fast), in: id) }
            catch { try? await bridge.end(id); throw error }
        }
        let opened = clock.now
        // 开工到会话连上分两段记下：起进程上桥，与第一句落成会话里的消息（`AgentTimeouts`）；慢在哪一段、超时在哪一段从这里看
        defer {
            AppServices.log.notice(
                "开新会话（\(launch.opening.rawValue, privacy: .public)）：起进程上桥 \(began.duration(to: opened), privacy: .public)，送开场 \(opened.duration(to: clock.now), privacy: .public)")
        }
        if let opening = launch.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !opening.isEmpty {
            guard let session = bridge.session(id: id) else {
                return .unconfirmed(ShownText("会话已经启动，但连接已断开，不会自动再开一个"))
            }
            do {
                return DeliveryRefusal.afterStarting(try await send(opening, of: request, to: session))
            } catch {
                // 已创建的会话不能因首句拒绝变成可安全重开；整个 start 意图保留未知。
                AppServices.log.error("会话已创建，开场消息未确认 \(request.id, privacy: .public)：\(String(describing: error), privacy: .public)")
                return .unconfirmed(ShownText(error))
            }
        }
        return .succeeded
    }

    private func writeTranscript(of sessionID: String) async throws {
        guard let indexed = try await store.indexedSession(sessionID) else { throw SendError.sessionFileMissing }
        try await store.writeTranscript(try await runtime(indexed.agent).transcript(of: indexed, files: store.files))
    }

    /// 手机只指名从哪里取，路径在这台 Mac 上解析，写进本机的目录绑定——绑定的唯一写入。按项目 id 记：项目记录晚到这台 Mac 也对得上。
    private func bindFolder(_ request: DeliveryRequest) async throws {
        guard let bind = request.bind else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
        guard let folder = bind.folder else { return try await store.setDirectory(nil, for: bind.project) }
        let directory = try await directory(of: folder)
        try requireDirectory(directory)
        try await store.setDirectory(directory.path, for: bind.project)
    }

    /// 没绑的建好工作区（已存在同名的直接用）并绑定；绑定照常发布给别的设备（`startDirectoryBindings`），之后与自己选的文件夹没有分别。
    private func workspace(of project: UUID) async throws -> URL {
        if let path = try await store.directory(of: project) { return URL(filePath: path, directoryHint: .isDirectory) }
        guard let name = try await store.project(project)?.name else { throw SendError.projectNotHere }
        let directory = workspaces.directory(for: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await store.setDirectory(directory.path(percentEncoded: false), for: project)
        return directory
    }

    private func requireDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SendError.directoryMissing(directory.lastPathComponent)
        }
    }

    private func directory(of folder: FolderSource) async throws -> URL {
        switch folder {
        case .project(let id):
            guard let path = try await store.directory(of: id) else {
                throw SendError.noCodeDirectory(try await store.project(id)?.name ?? "")
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        case .besideSession(let sessionID):
            if let live = bridge.session(sessionID: sessionID) { return live.cwd }
            guard let indexed = try await store.indexedSession(sessionID) else { throw SendError.sessionFileMissing }
            return URL(filePath: indexed.cwd, directoryHint: .isDirectory)
        }
    }
}
#endif
