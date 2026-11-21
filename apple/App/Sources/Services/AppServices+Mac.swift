#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation
import os

extension AppServices {
    func start() {
        guard !tasks.isRunning else { return }
        Self.raiseFileLimit()
        register(hotkey)
        startDiagnostics()
        let sessionChanges = bridge.changes()
        retireLegacySkill()
        do {
            try bridge.start()
        } catch {
            reportIssue(.bridgeUnavailable("\(error)"))
        }
        follow { [timing] in await self.historyStore.keepPruned(timing: timing) }
        startStrayFileCleanup()
        startDeliveryCleanup()
        startRuntimes()
        follow(reporting: { .syncUnavailable(String(localized: "Agent 状态没能写入同步记录：\(String(describing: $0))")) }) {
            try await self.consumeSessionChanges(sessionChanges)
        }
        follow(reporting: { .syncUnavailable(String(localized: "远程投送执行器没能启动：\(String(describing: $0))")) }) {
            try await self.executor.start()
        }
        follow(reporting: { .syncUnavailable(String(localized: "目录绑定没能同步给手机：\(String(describing: $0))")) }) { try await self.startDirectoryBindings() }
        follow(reporting: { .syncUnavailable(String(localized: "这台 Mac 在线的记录没能写下：\(String(describing: $0))")) }) { [presence, wakeNotifications] in
            try await presence.keep(notifications: wakeNotifications)
        }
        follow(reporting: { .syncUnavailable(String(localized: "这台 Mac 开着的页没能写下：\(String(describing: $0))")) }) { [viewer, wakeNotifications] in
            try await viewer.keep(notifications: wakeNotifications)
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
            reportIssue(.bridgeUnavailable("\(error)"))
        }
        follow { await self.indexAgents() }
    }

    func startWakeSync() {
        let wakes = wakeNotifications.notifications(named: NSWorkspace.didWakeNotification)
        follow {
            for await _ in wakes { await self.syncing.syncNow() }
        }
    }

    /// 主线程上的部分（后台任务、Pi 连接、全局快捷键）在这里同步做完；返回的等待只涉及不在主线程上的组件
    /// （远程投送执行器、同步），整体最多等 `limit`，自身不需要主线程：退出可能发生在主线程被占住时
    /// （在主线程上的任务里调用 terminate，系统在嵌套的事件循环里等回复，主线程上排队的任务轮不到）。
    /// 卡住、失败或缺少云端确认都如实报告，全部成功才返回 nil。
    func beginShutdown(within limit: Duration = .seconds(2)) -> @Sendable () async -> String? {
        let hosted = runtimes.values.map { $0.stop() }
        let hostedExit: @Sendable () async -> Void = { for exit in hosted { await exit() } }
        bridge.stop()
        hotkey.unregister()
        let signingOff = Task.detached { [presence] in try await presence.signOff() }
        let leaving = Task.detached { [viewer] in try await viewer.signOff() }
        let halted = halt()
        let log = Logger(subsystem: AppIdentity.id, category: "shutdown")
        return { @concurrent in
            let failure = await ShutdownSteps.run(halted.steps + [
                ("同步", {
                    _ = await signingOff.result
                    _ = await leaving.result
                    await halted.stopSync()
                }),
                ("这台 Mac 离线的记录", {
                    guard try await signingOff.value else { throw ShutdownSteps.UploadUnconfirmed() }
                }),
                ("这台 Mac 离开会话的记录", {
                    guard try await leaving.value != false else { throw ShutdownSteps.UploadUnconfirmed() }
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
        follow(reporting: { .bridgeUnavailable(String(localized: "Cue 没能值班：\(String(describing: $0))")) }) { try await self.cue.follow() }
        follow(reporting: { .bridgeUnavailable(String(localized: "Cue 的通知没能开始：\(String(describing: $0))")) }) { try await self.cue.followNotifications() }
    }


    func register(_ hotkey: GlobalHotkey) {
        if !hotkeys.contains(where: { $0 === hotkey }) { hotkeys.append(hotkey) }
        guard !DebugHooks.scripted else { return }
        do {
            try hotkey.registerSaved()
        } catch {
            reportIssue(.globalShortcutUnavailable(String(localized: "\(hotkey.label)（\(ShortcutText.display(hotkey.accelerator))）：\(String(describing: error))")))
        }
    }


    /// 设置里录新组合键期间全部让出：系统把注册着的组合直接吃掉，录的那一行收不到按键，按到自己占着的只会触发它。
    func suspendHotkeys() { hotkeys.forEach { $0.unregister() } }

    func resumeHotkeys() { hotkeys.forEach(register) }

    func rebind(_ hotkey: GlobalHotkey, to accelerator: String) throws {
        if let other = hotkeys.first(where: { $0 !== hotkey && $0.accelerator == accelerator }) { throw HotkeyError.taken(other.label) }
        try hotkey.set(accelerator)
    }

    nonisolated func loadHistoryStart(for file: URL) async -> HistoryStart? {
        do {
            return try await historyStore.start(for: file)
        } catch {
            await reportIssue(.historyUnavailable(String(localized: "读取 \(file.path) 的检查点失败：\(String(describing: error))")))
            return nil
        }
    }

    private func indexAgents() async {
        var indexing: [AgentKind: (connected: Bool, task: Task<Void, Never>)] = [:]
        defer { for entry in indexing.values { entry.task.cancel() } }
        let statuses = Observations { [settings] in AgentKind.allCases.map { settings.connectedAgents.contains($0) } }
        for await connected in statuses {
            for (agent, isConnected) in zip(AgentKind.allCases, connected) {
                guard indexing[agent]?.connected != isConnected else { continue }
                if let previous = indexing.removeValue(forKey: agent) {
                    previous.task.cancel()
                    await previous.task.value
                }
                if !isConnected {
                    do {
                        try await historyStore.forget(agent)
                    } catch {
                        reportIssue(.historyUnavailable(String(localized: "删掉 \(agent.name) 的会话索引失败：\(String(describing: error))")))
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
            let events = agent.confirmsFromHistory
                ? indexer.events(following: deliveryHistoryFiles(), scope: scope)
                : indexer.events(following: bridge.sessionFiles, scope: scope)
            return await consumeHistory(events, agent: agent)
        }
        guard connected, let runtime = runtimes[agent] else { return }
        do {
            try runtime.start()
        } catch {
            return reportIssue(.bridgeUnavailable(String(localized: "\(agent.name) 没能接上：\(String(describing: error))")))
        }
        let (untilCancelled, held) = AsyncStream<Never>.makeStream()
        for await _ in untilCancelled {}
        held.finish()
        await runtime.stop()()
    }

    private func hostedScope(of agent: AgentKind) async -> HistoryScope {
        do {
            return try await historyStore.hostedScope(of: agent)
        } catch {
            reportIssue(.historyUnavailable(String(localized: "读取 \(agent.name) 托管过的会话失败：\(String(describing: error))")))
            return .sessions([])
        }
    }

    static let backfillBatch = 200

    func consumeHistory(_ events: AsyncStream<HistoryEvent>, agent: AgentKind) async {
        await historyStore.beginBackfill()
        var pending: [HistoryUpdate] = []
        var backfilling = true
        func flush() async {
            guard !pending.isEmpty else { return }
            for failure in await historyStore.persist(pending) {
                reportIssue(.historyUnavailable(String(localized: "写入 \(failure.file.path) 失败：\(String(describing: failure.error))")))
            }
            pending.removeAll()
        }
        for await event in events {
            switch event {
            case .updated(let update):
                bridge.read(update)
                pending.append(update)
                if !backfilling || pending.count >= Self.backfillBatch { await flush() }
            case .backfillFinished(let files):
                await flush()
                backfilling = false
                do {
                    guard try await historyStore.backfillFinished(files, of: agent) else { continue }
                    try await stateRecorder.dropUnindexedHosted(of: agent)
                } catch {
                    reportIssue(.historyUnavailable(String(localized: "清理已不存在的会话失败：\(String(describing: error))")))
                }
            }
        }
        await flush()
    }
}

#endif
