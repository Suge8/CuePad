#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation
import os

extension AppServices {
    /// 幂等。窗口与 `windowShell` 就绪后调用。
    func start() {
        guard !tasks.isRunning else { return }
        Self.raiseFileLimit()
        register(hotkey)
        startDiagnostics()
        let piChanges = pi.changes() // 先订阅再启动桥与各家的接入：启动时发现的会话不能漏
        agents.uninstalled = { [weak self] kind in await self?.runtimes[kind]?.integrationRemoved() }
        agents.installed = { [weak self] kind in self?.runtimes[kind]?.integrationInstalled() }
        do {
            try pi.start()
            try hooks.start()
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        follow { await self.historyStore.keepPruned() }
        startStrayFileCleanup()
        // 启动对账在 `init` 里已做完（`launch`）：重新接上的会话沿用对账前的起点（`Bridge.carryOver`）
        startRuntimes()
        follow(reporting: { .syncUnavailable(String(localized: "Agent 状态没能写入同步记录：\(String(describing: $0))")) }) {
            try await self.consumePiChanges(piChanges)
        }
        // 执行器在接入刷新之后才启动：托管的 Pi 加载磁盘上的扩展，App 更新后要先换成随包版本，旧扩展读不懂托管约定。
        // 刷新失败也照样启动——托管启动时核对连上的扩展，对不上就让它退出并报错（`PiHostError.extensionMismatch`）。
        follow(reporting: { .syncUnavailable(String(localized: "远程投送执行器没能启动：\(String(describing: $0))")) }) {
            // 刷新不因取消抛错；退出收尾取消了这个任务时，迟到的 start 当场抛取消、不再起执行器（`DeliveryExecutor.start`）
            await self.refreshAgentIntegrations()
            try await self.executor.start()
        }
        follow(reporting: { .syncUnavailable(String(localized: "目录绑定没能同步给手机：\(String(describing: $0))")) }) { try await self.startDirectoryBindings() }
        follow(reporting: { .syncUnavailable(String(localized: "这台 Mac 在线的记录没能写下：\(String(describing: $0))")) }) { [presence, wakeNotifications] in
            try await presence.keep(notifications: wakeNotifications)
        }
        follow(reporting: { .syncUnavailable(String(localized: "这台 Mac 开着的页没能写下：\(String(describing: $0))")) }) { [viewer, wakeNotifications] in
            try await viewer?.keep(notifications: wakeNotifications)
        }
        follow(reporting: { .syncUnavailable(String(localized: "这台 Mac 上能用的 Agent 没能写下：\(String(describing: $0))")) }) { [macAgents, wakeNotifications] in
            try await macAgents.keep(notifications: wakeNotifications)
        }
        follow(reporting: { .syncUnavailable(String(localized: "这台 Mac 的技能与规则没能写下：\(String(describing: $0))")) }) { [library] in
            try await library.keep()
        }
        startCue()
        startSync()
        startRelay()
        startActivityPushes()
        startSpeechClock()
        startLiveSessions()
        startAccountQuotas()
        startAlerts()
    }

    private func startRuntimes() {
        do {
            for (agent, runtime) in runtimes where !runtimeIndexes(agent) { try runtime.start() }
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        follow { await self.indexAgents() }
    }

    private func refreshAgentIntegrations() async {
        do {
            try await agents.refresh()
        } catch where !Task.isCancelled {
            reportIssue(.piBridgeUnavailable(String(localized: "CuePad 写给 Agent 的技能或扩展没能升级：\(error.localizedDescription)")))
        } catch {}
    }

    /// 睡眠期间的推送可能没收到。
    /// 返回时已经订上：订阅放进任务里，任务跑起来之前的唤醒就丢了。
    func startWakeSync() {
        let wakes = wakeNotifications.notifications(named: NSWorkspace.didWakeNotification)
        follow {
            for await _ in wakes { await self.syncNow() }
        }
    }

    /// 主线程上的部分（后台任务、Pi 连接、全局快捷键）在这里同步做完；返回的等待只涉及不在主线程上的组件
    /// （远程投送执行器、同步），整体最多等 `limit`，自身不需要主线程：退出可能发生在主线程被占住时
    /// （在主线程上的任务里调用 terminate，系统在嵌套的事件循环里等回复，主线程上排队的任务轮不到）。
    /// 卡住、失败或缺少云端确认都如实报告，全部成功才返回 nil。
    func beginShutdown(within limit: Duration = .seconds(2)) -> @Sendable () async -> String? {
        cancelBackgroundWork()
        let hosted = runtimes.values.map { $0.stop() }
        let hostedExit: @Sendable () async -> Void = { for exit in hosted { await exit() } }
        hooks.stop()
        pi.stop()
        hotkey.unregister()
        // 离线这一条一开始收尾就写、就传，不排在别的组件停下之后：前面的步骤耗尽上限时它也已写下；停同步前等它传完
        let signingOff = Task.detached { [presence] in try await presence.signOff() }
        let leaving = Task.detached { [viewer] in try await viewer?.signOff() }
        let stopExecutor = executor.beginStop(), stopCue = cue.stop(), sync = sync
        let log = Logger(subsystem: AppIdentity.id, category: "shutdown")
        return { @concurrent in
            let failure = await ShutdownSteps.run([
                ("远程投送执行器", stopExecutor),
                ("Cue", stopCue),
                ("这台 Mac 离线的记录", {
                    guard try await signingOff.value else { throw ShutdownSteps.UploadUnconfirmed() }
                }),
                ("这台 Mac 离开会话的记录", {
                    guard try await leaving.value != false else { throw ShutdownSteps.UploadUnconfirmed() }
                }),
                ("同步", {
                    _ = await signingOff.result
                    _ = await leaving.result
                    await sync?.stop()
                }),
                ("后台托管的 Agent", hostedExit),
            ], within: limit)
            switch failure {
            case .timedOut(let component):
                log.error("退出收尾：\(component, privacy: .public) 没在 \(limit, privacy: .public) 内结束，已放行退出")
                return component
            case .failed(let component, let reason):
                return "\(component)：\(reason)"
            case nil: return nil
            }
        }
    }

    private func startCue() {
        follow(reporting: { .piBridgeUnavailable(String(localized: "Cue 没能值班：\(String(describing: $0))")) }) { try await self.cue.follow() }
        follow(reporting: { .piBridgeUnavailable(String(localized: "Cue 的通知没能开始：\(String(describing: $0))")) }) { try await self.cue.followNotifications() }
    }


    /// 脚本起的实例不注册：全局快捷键全机只有一份，会和用户在用的 CuePad 抢同一个键。
    func register(_ hotkey: GlobalHotkey) {
        guard !DebugHooks.scripted else { return }
        do {
            try hotkey.registerSaved()
        } catch {
            reportIssue(.globalShortcutUnavailable(String(localized: "\(hotkey.label)（\(ShortcutText.display(hotkey.accelerator))）：\(String(describing: error))")))
        }
    }


    /// 不经主线程：回填时每个文件都来取一次，主线程同时在画界面。
    nonisolated func loadHistoryStart(for file: URL) async -> HistoryStart? {
        do {
            return try await historyStore.start(for: file)
        } catch {
            await reportIssue(.piHistoryUnavailable(String(localized: "读取 \(file.path) 的检查点失败：\(String(describing: error))")))
            return nil
        }
    }

    /// 没接入的只有这台 Mac 托管过的会话（托管的会话没接入也开得出，`AgentProbe`）；
    /// 检测出没接入（关掉开关，或 CuePad 的文件被删了）时先删掉范围外会话的本机索引，会话的同步记录与对话不动。
    private func indexAgents() async {
        var indexing: [AgentKind: (connected: Bool, task: Task<Void, Never>)] = [:]
        defer { for entry in indexing.values { entry.task.cancel() } }
        let statuses = Observations { [agents] in AgentKind.allCases.map { agents.status($0)?.isConnected } }
        for await connected in statuses {
            for (agent, isConnected) in zip(AgentKind.allCases, connected) {
                guard let isConnected, indexing[agent]?.connected != isConnected else { continue }
                if let previous = indexing.removeValue(forKey: agent) {
                    previous.task.cancel()
                    await previous.task.value
                }
                if !isConnected {
                    do {
                        try await historyStore.forget(agent)
                    } catch {
                        reportIssue(.piHistoryUnavailable(String(localized: "删掉 \(agent.name) 的会话索引失败：\(String(describing: error))")))
                    }
                }
                indexing[agent] = (isConnected, Task { await self.index(agent, connected: isConnected) })
            }
        }
    }

    /// 文件描述符的软上限放到这台 Mac 允许的最大：图形应用默认只有 256，在线会话每个占一条桥上的连接，
    /// 会话文件再占一个（历史索引当场盯着它，`FileFollower`）。
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < rlim_t(OPEN_MAX) else { return }
        limit.rlim_cur = min(limit.rlim_max, rlim_t(OPEN_MAX))
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    private func runtimeIndexes(_ agent: AgentKind) -> Bool { paths.sessionsDirectory(of: agent) == nil }

    private func index(_ agent: AgentKind, connected: Bool) async {
        if let indexer = HistoryIndexer(
            agent: agent, paths: paths, transcriptWindow: Chat.transcriptWindow, files: store.files,
            start: { [weak self] file in await self?.loadHistoryStart(for: file) }) {
            let scope = connected ? .all : await hostedScope(of: agent)
            runtimes[agent]?.follow(scope)
            let events = agent == .pi
                ? indexer.events(following: piDeliveryHistoryFiles(), scope: scope)
                : indexer.events(following: pi.sessionFiles, scope: scope)
            return await consumePiHistory(events, agent: agent)
        }
        guard connected, let runtime = runtimes[agent] else { return }
        do {
            try runtime.start()
        } catch {
            return reportIssue(.piBridgeUnavailable(String(localized: "\(agent.name) 没能接上：\(String(describing: error))")))
        }
        let (untilCancelled, held) = AsyncStream<Never>.makeStream()
        for await _ in untilCancelled {}
        held.finish()
        await runtime.stop()()
    }

    /// 读不出来就只跟在线的。
    private func hostedScope(of agent: AgentKind) async -> HistoryScope {
        do {
            return try await historyStore.hostedScope(of: agent)
        } catch {
            reportIssue(.piHistoryUnavailable(String(localized: "读取 \(agent.name) 托管过的会话失败：\(String(describing: error))")))
            return .sessions([])
        }
    }

    /// 首次回填时攒够这么多个文件写一次（一个事务、一次变更通知）。
    static let backfillBatch = 200

    /// 先落检查点再写会话行；读到的会话名也交给这家的接入（会话状态有要从文件里得知的，`AgentRuntime.read`）。
    func consumePiHistory(_ events: AsyncStream<HistoryEvent>, agent: AgentKind) async {
        await historyStore.beginBackfill()
        var pending: [HistoryUpdate] = []
        var backfilling = true
        func flush() async {
            guard !pending.isEmpty else { return }
            for failure in await historyStore.persist(pending) {
                reportIssue(.piHistoryUnavailable(String(localized: "写入 \(failure.file.path) 失败：\(String(describing: failure.error))")))
            }
            pending.removeAll()
        }
        for await event in events {
            switch event {
            case .updated(let update):
                pi.read(update)
                runtimes[agent]?.read(update)
                pending.append(update)
                if !backfilling || pending.count >= Self.backfillBatch { await flush() }
            case .backfillFinished(let files):
                await flush()
                backfilling = false
                do {
                    // 只回填了托管过的会话：不知道其余会话文件还在不在，不对账
                    guard try await historyStore.backfillFinished(files, of: agent) else { continue }
                    try await piStateRecorder.dropUnindexedHosted(of: agent)
                } catch {
                    reportIssue(.piHistoryUnavailable(String(localized: "清理已不存在的会话失败：\(String(describing: error))")))
                }
            }
        }
        await flush()
    }

    func jumpToTerminal(_ id: CueBridge.Session.ID) async throws -> JumpResult {
        guard let session = pi.session(id: id) else { throw BridgeError.unknownSession(id) }
        return await terminal.jump(to: session)
    }
}

#endif
