#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 这台 Mac 上的投送请求执行器：领取发给本机的请求（手机发来的与本机界面写的），按发送方式执行，把结果写回。
/// 全 App 经桥给 Agent 会话发消息、作答、改配置、停止、结束，经各 Agent 的接入在后台开会话、接着会话的只有这里；成功送出的话记发送记录。
final class MacExecutor {
    private let store: CueStore
    private let pi: PiBridge
    private let runtimes: [AgentKind: any AgentRuntime]
    private let hostID: String
    private let workspaces: Workspaces
    private let recorder: PiStateRecorder
    private let library: AgentLibraryKeeper
    private let upload: @Sendable (UUID) async -> Void
    private let refreshQuota: @MainActor () async throws -> Void
    private let reportIssue: @MainActor (String) -> Void
    private var running: DeliveryExecutor?

    init(
        store: CueStore, pi: PiBridge, runtimes: [AgentKind: any AgentRuntime], hostID: String, workspaces: Workspaces, recorder: PiStateRecorder,
        library: AgentLibraryKeeper, upload: @escaping @Sendable (UUID) async -> Void,
        refreshQuota: @escaping @MainActor () async throws -> Void,
        reportIssue: @escaping @MainActor (String) -> Void
    ) {
        self.store = store
        self.pi = pi
        self.runtimes = runtimes
        self.hostID = hostID
        self.workspaces = workspaces
        self.recorder = recorder
        self.library = library
        self.upload = upload
        self.refreshQuota = refreshQuota
        self.reportIssue = reportIssue
    }

    func start() async throws {
        let executor = DeliveryExecutor(store: store, hostID: hostID, onIssue: { [reportIssue] error in
            let message = String(localized: "处理投送请求时读写资料库失败：\(error.localizedDescription)")
            Task { @MainActor in reportIssue(message) }
        }, onWritten: upload) { [weak self] request in
            guard let self else { return .failed(ShownText("这台 Mac 上的 CuePad 正在退出")) }
            return await self.run(request)
        }
        try await executor.start()
        running = executor
    }

    /// 立即不再领取新请求；返回的等待不在主线程上，退出收尾里与别的组件一起限时等（见 `AppServices.beginShutdown`）。
    func beginStop() -> @Sendable () async -> Void {
        let executor = running
        running = nil
        return { await executor?.stop() }
    }

    /// 执行一次，把错误归类交给 `DeliveryExecutor`（重试与写回在那里）：暂时性错误（`isTransient`）是暂时没成，其余是失败；
    /// 失败原因写回给发起的设备看：错误的句式与参数（`ShownText`，各端按自己的语言显示），系统与第三方的错误是这台的原文。
    /// 开新会话的错不算暂时性：起得慢的那个之后还会连上，再开一个就是两个会话。
    private func run(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            return try await perform(request)
        } catch {
            // 原因写回请求，请求完成后一分钟就清掉；日志里留一份，事后查得到是哪一步、什么错
            AppServices.log.error("投送请求 \(request.id, privacy: .public) \(request.mode.rawValue, privacy: .public) 没成：\(String(describing: error), privacy: .public)")
            return request.mode != .known(.start) && Self.isTransient(error) ? .transient(ShownText(error)) : .failed(ShownText(error))
        }
    }

    /// 暂时性错误：会话正在起、还没连上桥，话还没交出去，过一会儿再试不会说两遍。唤醒超时的几种都已让起到一半的进程退出，
    /// 重试不会多出一份。没等到确认（`ackTimeout`）、等确认时断开（`sessionEnded`）不算：话可能已经收下了，重试会说两遍。
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case PiBridgeError.unknownSession: true  // 会话刚唤醒，桥还没发现它的 socket
        case PiHostError.notConnected: true  // 唤醒已结束的 Pi 会话，它没及时连上桥
        case AgentRuntimeError.launchTimedOut: true  // 唤醒其余几家的会话，它没及时起来
        default: false
        }
    }

    /// 每种发送方式一个分支。不认识的方式 `DeliveryExecutor` 已按失败写回，走到这里的都是已知方式。
    private func perform(_ request: DeliveryRequest) async throws -> DeliveryOutcome {
        guard let mode = request.mode.known else { throw SendError.unsupportedMode(request.mode.rawValue) }
        switch mode {
        case .start: try await startSession(request)
        case .transcript: try await writeTranscript(of: request.content)
        case .bind: try await bindFolder(request)
        case .quota: try await refreshQuota()
        case .end: try await end(request.target)
        case .stop: try await stop(request.target)
        case .answer: try await answer(request)
        case .config: try await configure(request)
        case .command: try await runCommand(request)
        case .send: try await deliver(request)
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

    // MARK: 发给 Agent 会话

    /// 发出的话：会话在跑就由桥先打断这一轮（忙不忙以此刻为准，写请求时看到的"歇着"可能已过时），以这句开新一轮。
    /// 会话已结束时先在后台恢复；送出后记发送记录（带上请求 id，扩展写进会话文件的那条消息据此与请求气泡对上）。
    private func deliver(_ request: DeliveryRequest) async throws {
        let (_, id) = try await connect(request.target)
        guard let session = pi.session(id: id) else { throw PiBridgeError.unknownSession(id) }
        let content = SendContent(stored: request.content)
        try await pi.send(
            PiMessage(text: content.plainText, images: try content.piImages(from: store.files), deliveryID: request.id.uuidString), to: id)
        await record(request.content, of: request, to: session.sendTarget)
    }

    /// 记发送记录。话已经送达，记不下也照样按成功写回（手机才不会重发）：没记下是这台 Mac 的资料库问题，在这里报。
    private func record(_ content: String, of request: DeliveryRequest, to target: SendTarget) async {
        do {
            try await store.recordSend(content, to: target, card: request.cardID, delivery: request.id, origin: request.origin)
        } catch {
            reportIssue(String(localized: "处理投送请求时读写资料库失败：发送已完成，但没能记下这次发送：\(error.localizedDescription)"))
        }
    }

    /// 作答、改会话设置（会话名、模型、思考强度）与斜杠命令交给扩展，不是发出去的内容，不记发送记录。
    /// 会话已结束时与发消息一样先在后台恢复：改名对已结束的会话也要能做，Pi 只在活着的进程里写会话名。
    private func answer(_ request: DeliveryRequest) async throws {
        guard let answer = request.answer else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新答案
        let (_, id) = try await connect(request.target)
        try await pi.answer(answer.value, to: answer.promptID, in: id)
    }

    private func configure(_ request: DeliveryRequest) async throws {
        guard let config = request.config else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新强度，或什么都不改
        let (_, id) = try await connect(request.target)
        try await pi.configure(model: config.model, thinking: config.thinking, name: config.name, in: id)
    }

    /// 命令带着卡片（发给 Agent 时卡片文字是参数）：卡片关联到会话，但不写发送记录。
    private func runCommand(_ request: DeliveryRequest) async throws {
        let content = SendContent(stored: request.content)
        guard !content.hasImages else { throw SendError.imagesNotSupported }
        let (ref, id) = try await connect(request.target)
        try await pi.command(content.plainText.trimmingCharacters(in: .whitespacesAndNewlines), in: id)
        if let card = request.cardID { try await store.linkCard(card, toSession: ref) }
    }

    /// 结束会话（不写发送记录）：在桥上的先关掉它的进程；不在桥上的（托管着、进程已歇的，或早已结束的）没有进程可关，
    /// 不能为了结束它而恢复它。两种都由这里记为已结束、进历史——托管的会话闲置退出不算结束，只有用户的结束请求才算。
    private func end(_ target: SendTarget) async throws {
        let ref = try sessionID(of: target)
        if let live = pi.session(sessionID: ref) { try await pi.end(live.id) }
        try await recorder.end(sessionID: ref)
    }

    /// 停止这一轮（不写发送记录）：不在这台 Mac 的桥上的已经没有这一轮，目标达成，不恢复它。
    private func stop(_ target: SendTarget) async throws {
        guard let id = pi.session(sessionID: try sessionID(of: target))?.id else { return }
        try await pi.abort(id)
    }

    /// 请求指名的 Pi 会话（Pi 自己的会话 id）；别的目标是旧版本写的发到应用、剪贴板，按失败写回。
    private func sessionID(of target: SendTarget) throws -> String {
        guard target.kind == .known(.piSession) else { throw SendError.unsupportedTarget(target.name) }
        guard let ref = target.ref else { throw SendError.sessionNotOnThisMac(target.name) }
        return ref
    }

    /// 目标会话连着这台 Mac 的桥就用它，已结束的在后台恢复（会话索引里的会话文件与工作目录）。
    private func connect(_ target: SendTarget) async throws -> (sessionID: String, id: CuePi.PiSession.ID) {
        let ref = try sessionID(of: target)
        if let live = pi.session(sessionID: ref) { return (ref, live.id) }
        guard let indexed = try await store.piSession(ref) else { throw SendError.sessionNotOnThisMac(target.name) }
        try requireDirectory(URL(filePath: indexed.cwd, directoryHint: .isDirectory))
        return (ref, try await runtime(indexed.agent).resume(indexed))
    }

    /// 这个 Agent 在这台 Mac 上的接入；本版本不认识的 Agent 当作没装。
    private func runtime(_ agent: AgentKind) throws -> any AgentRuntime {
        guard let runtime = runtimes[agent] else { throw AgentRuntimeError.notInstalled(agent) }
        return runtime
    }

    // MARK: 不指向某个会话的请求（除开新会话的开场白外不写发送记录）

    /// 开新会话：在后台托管（各家的 `AgentRuntime`），目录由本机按项目绑定的文件夹解析（新会话的目录只由项目绑定推出；
    /// 这台 Mac 上还没绑的，先建好它的工作区并绑定，`workspace(of:)`）；
    /// 带上发起方的认领标识与会话名、模型、思考强度（Pi 的启动参数，一步生效：模型无效时 Pi 起不来，请求整体失败、不留会话），
    /// 连上后把开场的话作为第一条消息送进去（带着这条请求的 id，对话据此认出它），并记发送记录（同 `deliver`：请求清理后对话仍认得出是谁说的）。
    private func startSession(_ request: DeliveryRequest) async throws {
        guard let launch = request.launch else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
        let directory = try await workspace(of: launch.project)
        try requireDirectory(directory)
        let clock = ContinuousClock(), began = clock.now
        let id = try await runtime(launch.opening).open(
            in: directory, launchToken: launch.token, name: launch.name, model: launch.model, thinking: launch.thinking)
        let opened = clock.now
        // 开工到会话连上分两段记下：起进程上桥，与第一句落成会话里的消息（`AgentTimeouts`）；慢在哪一段、超时在哪一段从这里看
        defer {
            AppServices.log.notice(
                "开新会话（\(launch.opening.rawValue, privacy: .public)）：起进程上桥 \(began.duration(to: opened), privacy: .public)，送开场 \(opened.duration(to: clock.now), privacy: .public)")
        }
        if let opening = launch.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !opening.isEmpty {
            // 开场的话是存储格式（可带卡片里的图片）
            let content = SendContent(stored: opening)
            let text = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            try await pi.send(PiMessage(text: text, images: try content.piImages(from: store.files), deliveryID: request.id.uuidString), to: id)
            guard let session = pi.session(id: id) else { throw PiBridgeError.unknownSession(id) }
            await record(opening, of: request, to: session.sendTarget)
        }
    }

    /// 补写一个会话的对话：从头读出（会话文件，OpenCode 的经它的服务），与摘要一起写。
    private func writeTranscript(of sessionID: String) async throws {
        guard let indexed = try await store.piSession(sessionID) else { throw SendError.piSessionNotOnThisMac }
        try await store.writePiTranscript(try await runtime(indexed.agent).transcript(of: indexed, files: store.files))
    }

    /// 绑定文件夹：手机只指名从哪里取，路径在这台 Mac 上解析，写进本机的目录绑定——绑定的唯一写入；
    /// 目录绑定记录随之同步给手机。没有文件夹是解除。按项目 id 记：项目记录晚到这台 Mac 也对得上。
    private func bindFolder(_ request: DeliveryRequest) async throws {
        guard let bind = request.bind else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
        guard let folder = bind.folder else { return try await store.setDirectory(nil, for: bind.project) }
        let directory = try await directory(of: folder)
        try requireDirectory(directory)
        try await store.setDirectory(directory.path, for: bind.project)
    }

    /// 项目在这台 Mac 上的文件夹：绑着的就是它；没绑的建好工作区（`Workspaces.directory`，已存在同名的直接用）并绑定——
    /// 绑定照常发布给别的设备（`startDirectoryBindings`），之后与自己选的文件夹没有分别。
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

    private func directory(of folder: PiFolder) async throws -> URL {
        switch folder {
        case .project(let id):
            guard let path = try await store.directory(of: id) else {
                throw SendError.noCodeDirectory(try await store.project(id)?.name ?? "")
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        case .besideSession(let sessionID):
            if let live = pi.session(sessionID: sessionID) { return live.cwd }
            guard let indexed = try await store.piSession(sessionID) else { throw SendError.piSessionNotOnThisMac }
            return URL(filePath: indexed.cwd, directoryHint: .isDirectory)
        }
    }
}
#endif
