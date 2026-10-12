#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 这台 Mac 上的投送请求执行器：领取发给本机的请求（手机发来的与本机界面写的），按发送方式执行，把结果写回。
/// 全 App 调用 Pi 桥发消息、作答、改配置、停止与后台托管 Pi 的只有这里；成功送出的话记发送记录。
final class MacExecutor {
    private let store: CueStore
    private let pi: PiBridge
    private let host: any PiHosting
    private let hostID: String
    private let recorder: PiStateRecorder
    private let locatePi: @Sendable () async -> URL?
    private let uploadResult: @Sendable (UUID) async -> Void
    private let reportIssue: @MainActor (String) -> Void
    private var running: DeliveryExecutor?

    init(
        store: CueStore, pi: PiBridge, host: any PiHosting, hostID: String, recorder: PiStateRecorder,
        locatePi: @escaping @Sendable () async -> URL?,
        uploadResult: @escaping @Sendable (UUID) async -> Void,
        reportIssue: @escaping @MainActor (String) -> Void
    ) {
        self.store = store
        self.pi = pi
        self.host = host
        self.hostID = hostID
        self.recorder = recorder
        self.locatePi = locatePi
        self.uploadResult = uploadResult
        self.reportIssue = reportIssue
    }

    var isRunning: Bool { running != nil }

    func start() async throws {
        let executor = DeliveryExecutor(store: store, hostID: hostID, onIssue: { [reportIssue] error in
            let message = "处理投送请求时读写资料库失败：\(error.localizedDescription)"
            Task { @MainActor in reportIssue(message) }
        }, onFinished: uploadResult) { [weak self] request in
            guard let self else { return .failed("这台 Mac 上的 CuePad 正在退出") }
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

    /// 失败原因写回给手机用户看，取错误自身的说明（各模块的错误都实现了 `LocalizedError`）。
    private func run(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            try await perform(request)
            return .succeeded
        } catch SendError.unrecorded(let reason) {
            // 已经送达：写回成功，手机才不会重发；没记下发送是这台 Mac 的资料库问题，在这里报
            reportIssue("处理投送请求时读写资料库失败：\(reason)")
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 每种发送方式一个分支。不认识的方式 `DeliveryExecutor` 已按失败写回，走到这里的都是已知方式。
    private func perform(_ request: DeliveryRequest) async throws {
        guard let mode = request.mode.known else { throw SendError.unsupportedMode(request.mode.rawValue) }
        switch mode {
        case .ping: break  // 连接测试：收到即成功，不碰目标、不写发送记录
        case .start: try await startSession(request)
        case .transcript: try await writeTranscript(of: request.content)
        case .bind: try await bindFolder(request)
        case .end: try await end(request.target)
        case .stop: try await stop(request.target)
        case .answer: try await answer(request)
        case .config: try await configure(request)
        case .command: try await runCommand(request)
        case .send: try await deliver(request, whenBusy: nil)
        case .steer: try await deliver(request, whenBusy: .steer)
        case .followUp: try await deliver(request, whenBusy: .followUp)
        }
    }

    // MARK: 发给 Pi 会话

    /// 发出的话：Pi 桥只认 steer / followUp 两种入队方式（界面上叫马上说、等它做完再说），`whenBusy` 为 nil 的直接发送在会话正忙时报错。
    /// 会话已结束时先在后台恢复；送出后记发送记录（带上请求 id，扩展写进会话文件的那条消息据此与请求气泡对上）。
    private func deliver(_ request: DeliveryRequest, whenBusy: PiQueueMode?) async throws {
        let (_, id) = try await connect(request.target)
        guard let session = pi.session(id: id) else { throw PiBridgeError.unknownSession(id) }
        if whenBusy == nil, session.state.isTurnRunning { throw SendError.piSessionBusy }
        let content = SendContent(stored: request.content)
        try await pi.send(
            PiMessage(text: content.plainText, images: try piImages(in: content), whenBusy: whenBusy, deliveryID: request.id.uuidString), to: id)
        do {
            try await store.recordSend(request.content, to: session.sendTarget, card: request.cardID)
        } catch {
            throw SendError.unrecorded(error.localizedDescription)
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
        try await pi.command(content.plainText.trimmingCharacters(in: .whitespacesAndNewlines), whenBusy: .followUp, in: id)
        if let card = request.cardID { try await store.linkCard(card, toSession: ref) }
    }

    /// 结束会话（不写发送记录）：在桥上的先关掉它的进程；不在桥上的（托管着、进程已歇的，或早已结束的）没有进程可关，
    /// 不能为了结束它而恢复它。两种都由这里记为已结束、进历史——托管的会话闲置退出不算结束，只有用户的结束请求才算。
    private func end(_ target: SendTarget) async throws {
        let ref = try sessionID(of: target)
        if let id = pi.session(sessionID: ref)?.id { try await host.end(id) }
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
        let directory = URL(filePath: indexed.cwd, directoryHint: .isDirectory)
        try requireDirectory(directory)
        guard let executable = await locatePi() else { throw SendError.piNotInstalled }
        return (ref, try await host.resume(sessionFile: URL(filePath: indexed.path), in: directory, executable: executable))
    }

    // MARK: 不指向某个会话的请求（都不写发送记录）

    /// 开新会话：在后台托管（`PiHost`），目录由本机按项目绑定的文件夹解析（新会话的目录只由项目绑定推出）；
    /// 带上发起方的认领标识，连上后把开场的话作为第一条消息送进去（带着这条请求的 id，对话据此认出它）。
    private func startSession(_ request: DeliveryRequest) async throws {
        guard let launch = request.launch else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
        let directory = try await directory(of: .project(launch.project))
        try requireDirectory(directory)
        guard let executable = await locatePi() else { throw SendError.piNotInstalled }
        let id = try await host.open(in: directory, launchToken: launch.token, executable: executable)
        if let opening = launch.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !opening.isEmpty {
            // 开场的话是存储格式（可带卡片里的图片）
            let content = SendContent(stored: opening)
            let text = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            try await pi.send(PiMessage(text: text, images: try piImages(in: content), deliveryID: request.id.uuidString), to: id)
        }
    }

    /// 补写一个会话的对话：从本机的会话文件从头读出，与摘要一起写。
    private func writeTranscript(of sessionID: String) async throws {
        guard let indexed = try await store.piSession(sessionID) else { throw SendError.piSessionNotOnThisMac }
        try await store.writePiTranscript(try PiHistory.index(file: URL(filePath: indexed.path), from: nil).transcript)
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

    /// 正文里的图片按原顺序取原图与类型，交给 Pi 自行缩放。
    private func piImages(in content: SendContent) throws -> [PiImage] {
        try content.segments.compactMap { segment -> PiImage? in
            guard case .image(let hash) = segment else { return nil }
            let data = try store.files.original(hash)
            guard let mimeType = ImageFiles.mimeType(of: data) else { throw SendError.imageUnavailable(hash) }
            return PiImage(mimeType: mimeType, data: data)
        }
    }
}
#endif
