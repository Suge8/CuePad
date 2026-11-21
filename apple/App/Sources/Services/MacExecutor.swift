#if os(macOS)
import CueBridge
import CueStore
import Foundation

final class MacExecutor {
    let store: CueStore
    let bridge: Bridge
    private let runtimes: [AgentKind: any AgentRuntime]
    let hostID: String
    private let workspaces: Workspaces
    let recorder: StateRecorder
    private let library: AgentLibraryFiles
    private let fetchFile: FileFetching
    private let refreshQuota: AccountQuotas.Query
    private let reportIssue: @MainActor (String) -> Void
    private var running: DeliveryExecutor?

    init(
        store: CueStore, bridge: Bridge, runtimes: [AgentKind: any AgentRuntime], hostID: String, workspaces: Workspaces, recorder: StateRecorder,
        library: AgentLibraryFiles, fetchFile: @escaping FileFetching,
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
        self.fetchFile = fetchFile
        self.refreshQuota = refreshQuota
        self.reportIssue = reportIssue
    }

    func start() async throws {
        guard running == nil else { return }
        let executor = DeliveryExecutor(store: store, hostID: hostID, timing: store.timing, onIssue: { [reportIssue] error in
            let message = String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)")
            Task { @MainActor in reportIssue(message) }
        }, fetchFile: { [fetchFile] key in _ = try await fetchFile(key) }, recover: { [store, bridge] request in
            await DeliveryConfirmation(store: store, bridge: bridge).recover(request)
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

    func beginStop() -> @Sendable () async -> Void {
        let executor = running
        running = nil
        return { await executor?.stop() }
    }

    private func run(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async -> DeliveryOutcome {
        do {
            guard try await store.mayBeginDelivery(request.id) else { return .failed(DeliveryPreparation.abandoned) }
            return try await perform(request, access: access)
        } catch {
            AppServices.log.error("投送请求 \(request.id, privacy: .public) \(request.mode.rawValue, privacy: .public) 没成：\(String(describing: error), privacy: .public)")
            return DeliveryRefusal.definitelyNotHanded(request.mode, error) ? .failed(ShownText(error)) : .unconfirmed(ShownText(error))
        }
    }

    private func perform(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws -> DeliveryOutcome {
        guard let mode = request.mode.known else { throw SendError.unsupportedMode(request.mode.rawValue) }
        switch mode {
        case .withdraw: preconditionFailure("撤回由 DeliveryExecutor 在库里办，不交给这里")
        case .start: return try await startSession(request)
        case .transcript: try await writeTranscript(of: request.content)
        case .step: try await AppServices.fillStep(request.content, in: store, runtimes: runtimes)
        case .bind: try await bindFolder(request)
        case .quota: if let failure = await refreshQuota() { return .failed(failure) }
        case .end: try await end(request)
        case .stop: try await stop(request.target)
        case .retry: try await retry(request.target)
        case .answer: try await answer(request, access: access)
        case .config: try await configure(request, access: access)
        case .command: try await runCommand(request, access: access)
        case .send: return try await deliver(request, access: access)
        case .tidy:
            guard let orders = request.tidyOrders else { throw SendError.unsupportedMode(request.mode.rawValue) }
            _ = try await library.tidy(orders)
        case .libraryEdit:
            guard let edit = request.libraryEdit else { throw SendError.unsupportedMode(request.mode.rawValue) }
            try await library.write(edit)
        }
        return .succeeded
    }


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
        let outgoing = try DeliveryMessage.make(content, request: request, session: session, files: store.files)
        guard try await store.mayBeginDelivery(request.id) else { return .failed(DeliveryPreparation.abandoned) }
        try Task.checkCancellation()
        do { try await bridge.send(outgoing, to: session.id) }
        catch {
            guard session.agent == .pi, !DeliveryRefusal.definitelyNotHanded(request.mode, error) else { throw error }
            return DeliveryConfirmation(store: store, bridge: bridge).pending(in: session, reason: ShownText(error))
        }
        do {
            try await store.linkDeliveredCard(request, toSession: session.sessionID)
        } catch {
            reportIssue(String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)"))
        }
        guard !session.confirmsFromHistory else {
            return DeliveryConfirmation(store: store, bridge: bridge).pending(in: session)
        }
        await record(content, of: request, to: session.sendTarget)
        return .succeeded
    }

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
        guard let answer = request.answer else { throw SendError.unsupportedMode(request.mode.rawValue) }
        let (_, id, _) = try await connect(request.target, access: access)
        try await bridge.answer(answer.value, to: answer.promptID, in: id)
    }

    private func configure(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws {
        guard let config = request.config else { throw SendError.unsupportedMode(request.mode.rawValue) }
        let (_, id, _) = try await connect(request.target, access: access)
        try await bridge.configure(config, in: id)
    }

    private func runCommand(_ request: DeliveryRequest, access: DeliveryAdmission.Access) async throws {
        let content = SendContent(stored: request.content)
        let (ref, id, _) = try await connect(request.target, access: access)
        let line = try content.agentText(from: store.files, imagesAsFiles: true).trimmingCharacters(in: .whitespacesAndNewlines)
        try await bridge.command(line, opener: TurnOpener(delivery: request.id, cue: request.isFromCue), in: id)
        do { try await store.linkDeliveredCard(request, toSession: ref) } catch {
            reportIssue(String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)"))
        }
    }

    private func connect(_ target: SendTarget, access: DeliveryAdmission.Access) async throws -> (sessionID: String, id: CueBridge.Session.ID, resumed: Bool) {
        let ref = try sessionID(of: target)
        if let live = bridge.session(sessionID: ref) { return (ref, live.id, false) }
        if case .existingOnly = access { throw SendError.sessionNotOnThisMac(target.name) }
        guard let indexed = try await store.indexedSession(ref) else { throw SendError.sessionNotOnThisMac(target.name) }
        try requireDirectory(URL(filePath: indexed.cwd, directoryHint: .isDirectory))
        try Task.checkCancellation()
        return (ref, try await runtime(indexed.agent).resume(indexed), true)
    }

    private func runtime(_ agent: AgentKind) throws -> any AgentRuntime {
        guard let runtime = runtimes[agent] else { throw AgentRuntimeError.notInstalled(agent) }
        return runtime
    }

    // MARK: 不指向某个会话的请求（除开新会话的开场白外不写发送记录）

    /// 目录由本机按项目绑定的文件夹解析；这台 Mac 上还没绑的，先建好工作区并绑定（`workspace(of:)`）。
    /// 模型、思考强度是 Pi 的启动参数，一步生效：模型无效时 Pi 起不来，请求整体失败、不留会话。
    /// 开场的话带着这条请求的 id（对话据此认出它），并记发送记录（同 `deliver`：请求清理后对话仍认得出是谁说的）。
    private func startSession(_ request: DeliveryRequest) async throws -> DeliveryOutcome {
        guard let launch = request.launch else { throw SendError.unsupportedMode(request.mode.rawValue) }
        let directory = try await workspace(of: launch.project)
        try requireDirectory(directory)
        let clock = ContinuousClock(), began = clock.now
        let id = try await runtime(launch.agent).open(
            in: directory, launchToken: launch.token, name: launch.name, model: launch.model, thinking: launch.thinking)
        if launch.fast || bridge.session(id: id)?.fast == true {
            do { try await bridge.configure(SessionConfig(fast: launch.fast), in: id) }
            catch { try? await bridge.end(id); throw error }
        }
        let opened = clock.now
        defer {
            AppServices.log.notice(
                "开新会话（\(launch.agent.rawValue, privacy: .public)）：起进程上桥 \(began.duration(to: opened), privacy: .public)，送开场 \(opened.duration(to: clock.now), privacy: .public)")
        }
        if let opening = launch.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !opening.isEmpty {
            guard let session = bridge.session(id: id) else {
                return .unconfirmed(ShownText("会话已经启动，但连接已断开，不会自动再开一个"))
            }
            do {
                return DeliveryRefusal.afterStarting(try await send(opening, of: request, to: session))
            } catch {
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

    private func bindFolder(_ request: DeliveryRequest) async throws {
        guard let bind = request.bind else { throw SendError.unsupportedMode(request.mode.rawValue) }
        guard let folder = bind.folder else { return try await store.setDirectory(nil, for: bind.project) }
        let directory = try await directory(of: folder)
        try requireDirectory(directory)
        try await store.setDirectory(directory.path, for: bind.project)
    }

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
