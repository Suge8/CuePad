#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import Foundation

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么），
/// 并执行手机发来、指定给这台 Mac 的投送请求。
extension AppServices {
    // MARK: Pi 状态记录

    /// 启动时清掉这台 Mac 上次没来得及结束的会话记录（别的 Mac 的不动）。
    func resetPiState() async throws {
        try await piStateRecorder.reset()
    }

    /// 把 Pi 桥的会话变化写成同步记录，直到流结束。
    func consumePiChanges(_ changes: AsyncStream<PiSessionChange>) async throws {
        for await change in changes {
            switch change {
            case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session):
                try await recordPiState(of: session)
            case .ended(let session, _): try await piStateRecorder.end(sessionID: session.sessionID)
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
            recap: PiRecap(lastPrompt: session.lastPrompt, lastReply: session.lastReply, question: session.question.map(PiQuestion.init)),
            times: PiTimes(stateSince: session.stateSince, busySince: session.busySince), launchToken: session.launchToken)
    }

    // MARK: 投送请求（手机发来的与本机界面写的）

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
        if request.mode == .known(.resume) || request.mode == .known(.start) {
            guard let launch = request.launch else { throw SendError.unsupportedMode(request.mode.rawValue) }  // 更新版本写的新内容
            return try await launchPi(launch)
        }
        let target = request.target
        let content = SendContent(stored: request.content)
        let sent: SendTarget
        switch target.kind {
        case .known(.piSession):
            guard let ref = target.ref, let id = channels.piSessionID(forSession: ref) else {
                throw SendError.sessionNotOnThisMac(target.name)
            }
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

    /// 在设置里选的终端里恢复或新开 Pi 会话（不写发送记录）。目录由本机解析：恢复用会话索引里的工作目录与会话文件；
    /// 新会话用项目绑定的代码目录或某个会话的目录。新会话经环境变量带上发起方的认领标识，扩展在 hello 里带回。
    private func launchPi(_ launch: PiLaunch) async throws {
        guard let pi = await locatePi() else { throw SendError.piNotInstalled }
        let command: TerminalCommand
        switch launch {
        case .resume(let sessionID):
            guard channels.piSessionID(forSession: sessionID) == nil else { throw SendError.piSessionAlreadyRunning }
            guard let indexed = try await store.piSession(sessionID) else { throw SendError.piSessionNotOnThisMac }
            command = TerminalCommand(
                directory: URL(filePath: indexed.cwd, directoryHint: .isDirectory), executable: pi,
                arguments: ["--session", indexed.path], environment: [:])
        case .start(let place, let prompt, let token):
            let opening = prompt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            command = TerminalCommand(
                directory: try await directory(for: place), executable: pi,
                // `--` 之后都是开场的话，以 - 开头也不会被当成选项
                arguments: opening.map { ["--", $0] } ?? [], environment: [Self.launchTokenVariable: token])
        }
        try await terminalLauncher.open(command, in: settings.piTerminal)
    }

    /// 扩展读这个环境变量拿认领标识（见扩展的 `LAUNCH_TOKEN_ENV`）。
    static let launchTokenVariable = "CUEPAD_LAUNCH_TOKEN"

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
        case .answer, .ping, .resume, .start: throw SendError.unsupportedMode(mode.rawValue)  // 这几种在 perform 里处理，不走发送
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
    /// 写进同步记录（与 Mac 的近况页）的状态与一句话说明：会话自己没有说明时写子代理摘要。
    var syncRepresentation: (state: PiWorkState, detail: String?) {
        let (state, detail) = state.syncRepresentation
        return (state, detail ?? subagentSummary)
    }
}

extension PiAgentState {
    /// 写进同步记录的状态与一句话说明。
    var syncRepresentation: (state: PiWorkState, detail: String?) {
        switch self {
        case .idle, .done: (.settled, nil)
        case .thinking: (.thinking, nil)
        case .outputting: (.outputting, nil)
        case .delegating: (.delegating, nil)  // 说明写子代理摘要
        case .tool(let name, _, let detail): (.tool, detail.map { "\(name) · \($0)" } ?? name)
        case .waitingUser(_, let title): (.waitingForUser, title)
        case .error(let message): (.error, PiErrorSummary(message).line)  // 手机上没有悬停看原文
        }
    }
}
#endif
