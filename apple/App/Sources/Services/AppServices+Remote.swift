#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import Foundation
import SystemConfiguration

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么），
/// 并执行手机发来、指定给这台 Mac 的投送请求。
extension AppServices {
    // MARK: Pi 状态记录

    /// 启动时清掉这台 Mac 上次没来得及结束的会话记录（别的 Mac 的不动）。
    func resetPiState() async throws {
        try await piStateRecorder.reset()
    }

    /// 把 Pi 桥的会话变化写成同步记录，直到流结束。一个会话一条记录：同一会话同时有两个进程（后台托管的那个正在让给
    /// 用户在终端里打开的那个）时，记录跟着用户的；其中一个结束而另一个还在时，记录不标为结束。
    func consumePiChanges(_ changes: AsyncStream<PiSessionChange>) async throws {
        var live: [CuePi.PiSession.ID: CuePi.PiSession] = [:]
        func owner(of sessionID: String) -> CuePi.PiSession? {
            let processes = live.values.filter { $0.sessionID == sessionID }
            return processes.first { !$0.hosted } ?? processes.first
        }
        for await change in changes {
            switch change {
            case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session):
                live[session.id] = session
                if owner(of: session.sessionID)?.id == session.id { try await recordPiState(of: session) }
            case .ended(let session, _):
                live[session.id] = nil
                if let other = owner(of: session.sessionID) {
                    try await recordPiState(of: other)
                } else {
                    try await piStateRecorder.end(sessionID: session.sessionID)
                }
            case .incompatible: break
            }
        }
    }

    private func recordPiState(of session: CuePi.PiSession) async throws {
        let (state, detail) = session.syncRepresentation
        try await piStateRecorder.update(
            sessionID: session.sessionID, state: state, detail: detail, title: session.displayName,
            folder: session.cwd.lastPathComponent,
            projectID: try await store.project(containing: session.cwd)?.id,
            recap: PiRecap(
                lastPrompt: session.lastPrompt, lastReply: session.lastReply, pendingPrompt: session.pendingPrompt,
                question: session.question.map(PiQuestion.init)),
            times: PiTimes(stateSince: session.stateSince, busySince: session.busySince), launchToken: session.launchToken,
            hosted: session.hosted, subagents: session.subagentStates)
    }

    // MARK: 投送请求（手机发来的与本机界面写的）

    /// 本机的目录绑定写成同步的目录绑定记录（手机据此知道哪些项目能在哪台 Mac 上开新会话）：先对一次，
    /// 之后本机绑定每次变化时跟上，直到后台任务取消。
    func startDirectoryBindings() async throws {
        let host = hostID
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        try await store.publishDirectoryBindings(host: host, hostName: name)
        let changes = store.observe([.projectDirectories]) { _ in () }
        tasks.append(Task { [store, weak self] in
            do {
                for try await _ in changes { try await store.publishDirectoryBindings(host: host, hostName: name) }
            } catch {
                self?.reportIssue(.syncUnavailable("目录绑定没能同步给手机：\(error)"))
            }
        })
    }

    func startDeliveryExecutor() async throws {
        let executor = DeliveryExecutor(store: store, hostID: hostID, onIssue: { [weak self] error in
            let message = "处理投送请求时读写资料库失败：\(error.localizedDescription)"
            Task { @MainActor in self?.reportIssue(.syncUnavailable(message)) }
        }, onFinished: { [weak self] id in await self?.upload(id) }) { [weak self] request in
            guard let self else { return .failed("这台 Mac 上的 CuePad 正在退出") }
            return await self.execute(request)
        }
        try await executor.start()
        deliveryExecutor = executor
    }

    /// 失败原因写回给手机用户看，取错误自身的说明（各模块的错误都实现了 `LocalizedError`）。
    private func execute(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            try await perform(request)
            return .succeeded
        } catch SendError.unrecorded(let reason) {
            // 已经送达：写回成功，手机才不会重发；没记下发送是这台 Mac 的资料库问题，在这里报
            reportIssue(.syncUnavailable("处理投送请求时读写资料库失败：\(reason)"))
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 执行一条请求：发给 Pi 会话的在这里调用 Pi 桥（全 App 只有这一处），应用与剪贴板交给通用发送；成功后记发送记录。
    private func perform(_ request: DeliveryRequest) async throws {
        if request.mode == .known(.ping) { return }  // 连接测试：收到即成功，不碰目标、不写发送记录
        if request.mode == .known(.start) {
            guard let launch = request.launch else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
            return try await startPi(launch)
        }
        let target = request.target
        let content = SendContent(stored: request.content)
        let sent: SendTarget
        switch target.kind {
        case .known(.piSession):
            guard let ref = target.ref else { throw SendError.sessionNotOnThisMac(target.name) }
            let id = if let live = channels.piSessionID(forSession: ref) { live } else { try await resumeInBackground(ref, name: target.name) }
            // 执行器已把不认识的发送方式按失败写回，走到这里的都是已知方式
            guard let mode = request.mode.known else { throw SendError.unsupportedMode(request.mode.rawValue) }
            if mode == .answer {
                // 作答不是发出去的内容，不记发送记录
                guard let answer = request.answer else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新答案
                try await channels.answer(answer.value.prompt, to: answer.promptID, in: id)
                return
            }
            sent = try await sendToPi(content, session: id, mode: mode)
        case .known(.app):
            guard let bundleID = target.ref else { throw SendError.unsupportedTarget(target.name) }
            sent = try await dispatch(content, to: .bundleID(bundleID), submit: settings.autoSubmit)
        case .known(.clipboard):
            sent = try copyToClipboard(content)
        case .unknown:
            throw SendError.unsupportedTarget(target.name)
        }
        try await recordSend(request.content, to: sent, card: request.cardID, task: request.taskID)
    }

    /// 开新会话（不写发送记录）：在后台托管（`PiHost`），目录由本机解析：项目绑定的代码目录或某个会话的目录；
    /// 带上发起方的认领标识，连上后把开场的话作为第一条消息送进去。
    private func startPi(_ launch: PiLaunch) async throws {
        let directory = try await directory(for: launch.place)
        try requireDirectory(directory)
        guard let pi = await locatePi() else { throw SendError.piNotInstalled }
        let id = try await host.open(in: directory, launchToken: launch.token, executable: pi)
        if let opening = launch.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !opening.isEmpty {
            try await channels.send(PiMessage(text: opening), to: id)
        }
    }

    /// 发给已结束的会话：在后台把它恢复起来（会话索引里的会话文件与工作目录），返回连上桥的会话。
    private func resumeInBackground(_ sessionID: String, name: String) async throws -> CuePi.PiSession.ID {
        guard let indexed = try await store.piSession(sessionID) else { throw SendError.sessionNotOnThisMac(name) }
        let directory = URL(filePath: indexed.cwd, directoryHint: .isDirectory)
        try requireDirectory(directory)
        guard let pi = await locatePi() else { throw SendError.piNotInstalled }
        return try await host.resume(sessionFile: URL(filePath: indexed.path), in: directory, executable: pi)
    }

    private func requireDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SendError.directoryMissing(directory.lastPathComponent)
        }
    }

    private func directory(for place: PiLaunchPlace) async throws -> URL {
        switch place {
        case .project(let id):
            guard let path = try await store.directory(of: id) else {
                throw SendError.noCodeDirectory(try await store.project(id)?.name ?? "")
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        case .besideSession(let sessionID):
            if let live = pi.sessions.first(where: { $0.sessionID == sessionID }) { return live.cwd }
            guard let indexed = try await store.piSession(sessionID) else { throw SendError.piSessionNotOnThisMac }
            return URL(filePath: indexed.cwd, directoryHint: .isDirectory)
        }
    }

    /// Pi 桥只认插话/排队两种入队方式：发送方式在这里一次性落到桥的消息上。
    private func sendToPi(_ content: SendContent, session id: CuePi.PiSession.ID, mode: DeliveryMode) async throws -> SendTarget {
        guard let session = channels.piSession(id) else { throw PiBridgeError.unknownSession(id) }
        let whenBusy: PiQueueMode?
        switch mode {
        case .paste:
            guard !content.hasImages else { throw SendError.imagesNotSupported }
            try await channels.paste(content.plainText, into: id)
            return session.target
        case .send:
            guard !session.isBusy else { throw SendError.piSessionBusy }
            whenBusy = nil
        case .steer: whenBusy = .steer
        case .followUp: whenBusy = .followUp
        case .answer, .ping, .start: throw SendError.unsupportedMode(mode.rawValue)  // 这几种在 perform 里处理，不走发送
        }
        let images = try content.segments.compactMap { segment -> PiImage? in
            guard case .image(let hash) = segment else { return nil }
            let data = try imageData(hash)
            guard let mimeType = ImageFiles.mimeType(of: data) else { throw SendError.imageUnavailable(hash) }
            return PiImage(mimeType: mimeType, data: data)
        }
        try await channels.send(PiMessage(text: content.plainText, images: images, whenBusy: whenBusy), to: id)
        return session.target
    }
}

extension PiQuestion {
    /// 桥上的弹窗写成同步记录里的问题（扩展的种类名与这里同名）。
    init(_ prompt: PiPrompt) {
        self.init(promptID: prompt.id, kind: Open(rawValue: prompt.kind), text: prompt.text, options: prompt.options)
    }
}

extension PiAnswerValue {
    /// 交给桥的回答。
    var prompt: PiPromptAnswer {
        switch self {
        case .option(let option): .option(option)
        case .confirmed(let confirmed): .confirmed(confirmed)
        case .text(let text): .text(text)
        }
    }
}

extension CuePi.PiSession {
    /// 写进同步记录（与 Mac 的近况页）的状态与一句话说明。
    var syncRepresentation: (state: PiWorkState, detail: String?) { state.syncRepresentation }

    /// 写进同步记录的子代理列表。
    var subagentStates: [PiSubagentState] {
        subagents.map { subagent in
            let activity: PiSubagentActivity =
                switch subagent.activity {
                case .working: .working
                case .waitingForUser: .waitingForUser
                case .idle: .idle
                case .error: .error
                }
            return PiSubagentState(name: subagent.name, activity: .known(activity))
        }
    }
}

extension PiAgentState {
    /// 写进同步记录的状态与一句话说明。
    var syncRepresentation: (state: PiWorkState, detail: String?) {
        switch self {
        case .idle, .done: (.settled, nil)
        case .thinking: (.thinking, nil)
        case .outputting: (.outputting, nil)
        case .delegating: (.delegating, nil)  // 子代理在 `subagents` 里
        case .tool(let name, _, let detail): (.tool, detail.map { "\(name) · \($0)" } ?? name)
        case .waitingUser(_, let title): (.waitingForUser, title)
        case .error(let message): (.error, PiErrorSummary(message).line)  // 手机上没有悬停看原文
        }
    }
}
#endif
