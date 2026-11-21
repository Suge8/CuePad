#if os(macOS)
import AppKit
import CueStore

extension Workspace {
    func serveLiveAgent() async {
        let path = LiveChannel.socketPath(databasePath: services.store.databasePath)
        let server: LiveChannel.Server
        do {
            server = try LiveChannel.Server(path: path, store: services.store) { request in await self.answerLive(request) }
        } catch {
            return fail(error)
        }
        let monitor = watchUserInput()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await releaseLivePreviews(at: .now)
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        withExtendedLifetime(server) {}
    }

    func answerLive(_ request: LiveChannel.Request) async -> LiveChannel.Reply {
        let id = SessionState.recordID(sessionID: request.session)
        let before = liveTurns[id]
        let turn = Task {
            _ = await before?.value
            return await performLive(request, id)
        }
        liveTurns[id] = turn
        let reply = await withTaskCancellationHandler { await turn.value } onCancel: { turn.cancel() }
        if liveTurns[id] == turn { liveTurns[id] = nil }
        return reply
    }

    private func performLive(_ request: LiveChannel.Request, _ id: UUID) async -> LiveChannel.Reply {
        guard !Task.isCancelled else { return .refused("取消了") }
        do {
            let (preview, rebuilt) = try await livePreview(forAgent: request.session, id)
            await preview.touchedByAgent()
            defer { preview.agent.used = .now }
            let args = request.args
            let colors = preview.pickColors
            let mark = (tint: colors["tint"] ?? "", ink: colors["ink"] ?? "")
            var reply: LiveChannel.Reply
            switch request.op {
            case "snapshot": reply = try await preview.agentSnapshot(args)
            case "screenshot": reply = try await preview.agentScreenshot(args)
            case "console": reply = preview.agentConsole(args)
            case "wait": reply = try await preview.agentWait(args)
            case "click": reply = try await preview.agentAct(.click(try Self.need(args.ref)), mark: mark)
            case "fill": reply = try await preview.agentAct(.fill(try Self.need(args.ref), args.text ?? ""), mark: mark)
            case "press": reply = try await preview.agentAct(.press(try Self.need(args.key), args.ref), mark: mark)
            case "upload": reply = try await preview.agentAct(.upload(try Self.need(args.ref), args.files ?? []), mark: mark)
            case "eval": reply = try await preview.agentAct(.eval(try Self.need(args.code)), mark: mark)
            default: throw LiveRefusal("不认识 cuepad live \(request.op)：命令行比开着的 CuePad 新，请用户更新 CuePad")
            }
            if rebuilt {
                reply.text = "（这个预览闲置超过 \(Self.liveIdle.components.seconds / 60) 分钟被释放过，这是重新载入的页面：之前页面里的状态与登录都没了）\n" + reply.text
            }
            return reply
        } catch let refusal as LiveRefusal {
            return .refused(refusal.text)
        } catch is CancellationError {
            return .refused("取消了")
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    private static func need<T>(_ value: T?) throws -> T {
        guard let value else { throw LiveRefusal("请求缺参数：命令行与开着的 CuePad 不是同一版") }
        return value
    }

    private func livePreview(forAgent sessionID: String, _ id: UUID) async throws -> (LivePreview, rebuilt: Bool) {
        take(try await services.store.liveAddresses())
        if let preview = livePreviews[id] { return (preview, false) }
        guard let sent = liveSent.removeValue(forKey: id) else {
            throw LiveRefusal("这个会话还没有活预览：先 cuepad live（或 cuepad live <端口>）把页面开在 CuePad 里，再操作它")
        }
        let preview = LivePreview()
        preview.sessionID = sessionID
        preview.retarget(sent)
        preview.start()
        preview.engage()
        livePreviews[id] = preview
        return (preview, liveReleased.remove(id) != nil)
    }

    func releaseLivePreviews(at now: ContinuousClock.Instant) async {
        let open = Set(((try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]).keys)
        for preview in livePreviews.values where now - preview.agent.acted > Self.liveIdle { preview.disengage() }
        for (id, preview) in livePreviews where !showsLivePreview(id) {
            var ended = false
            if let sessionID = preview.sessionID, !open.contains(sessionID), let state = try? await services.store.sessionState(sessionID) {
                ended = state.state == .known(.ended)
            }
            guard ended || now - preview.agent.used > Self.liveIdle, livePreviews[id] === preview, !showsLivePreview(id) else { continue }
            // 弹着的对话框先答掉：网页的脚本停在那一句上等着
            for ask in preview.asks { preview.answer(ask.id, nil) }
            preview.disengage()
            livePreviews[id] = nil
            if ended {
                liveSent[id] = nil
                liveReleased.remove(id)
            } else {
                if liveSent[id] == nil, let address = preview.address { liveSent[id] = .init(url: address, source: preview.source) }
                liveReleased.insert(id)
            }
        }
    }

    static let liveIdle = Duration.seconds(600)

    private func watchUserInput() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.noteUserInput(event) }
            return event
        }
    }

    private func noteUserInput(_ event: NSEvent) {
        guard let window = event.window else { return }
        for preview in livePreviews.values where preview.web.window === window {
            let web = preview.web
            let inside = if event.type == .keyDown {
                (window.firstResponder as? NSView)?.isDescendant(of: web) == true
            } else {
                web.bounds.contains(web.convert(event.locationInWindow, from: nil))
            }
            if inside { preview.agent.userInput = .now }
        }
    }
}
#endif
