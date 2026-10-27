#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation
import os
import Synchronization

/// macOS 壳层与后台服务的生命周期：启动、停止、全局快捷键、Agent 会话历史索引、终端跳转。
extension AppServices {
    /// 幂等。窗口与 `windowShell` 就绪后调用。
    func start() {
        guard !tasks.isRunning else { return }
        Self.raiseFileLimit()
        register(hotkey)
        if location.touchesRealWorld { diagnostics.start() }
        let piChanges = pi.changes() // 先订阅再启动桥与各家的接入：启动时发现的会话不能漏
        let legacyPiChanges = pi.changes()
        agents.uninstalled = { [weak self] kind in await self?.runtimes[kind]?.integrationRemoved() }
        agents.installed = { [weak self] kind in self?.runtimes[kind]?.integrationInstalled() }
        do {
            try pi.start()
            try hooks.start()
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        follow { await self.historyStore.keepPruned() }
        // 先对账再起各家的接入：重新接上的会话沿用对账前的起点（`PiBridge.carryOver`）。对账失败照样起，只是从此刻算
        follow(reporting: { .syncUnavailable(String(localized: "Agent 状态没能写入同步记录：\(String(describing: $0))")) }) {
            var failure: (any Error)?
            do { try await self.resetPiState() } catch { failure = error }
            self.startRuntimes()
            if let failure { throw failure }
            try await self.consumePiChanges(piChanges)
        }
        // 执行器在接入刷新之后才启动：托管的 Pi 加载磁盘上的扩展，App 更新后要先换成随包版本，旧扩展读不懂托管约定。
        // 刷新失败也照样启动——托管启动时核对连上的扩展，对不上就让它退出并报错（`PiHostError.extensionMismatch`）。
        follow(reporting: { .syncUnavailable(String(localized: "远程投送执行器没能启动：\(String(describing: $0))")) }) {
            await self.refreshAgentIntegrations()
            try await self.executor.start()
        }
        follow(reporting: { .piBridgeUnavailable(String(localized: "旧版 Pi 扩展文件没能删掉：\(String(describing: $0))")) }) {
            try await self.agents.retireLegacyPiExtension(following: legacyPiChanges)
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
        startSpeechClock()
        startLiveSessions()
        startAccountQuotas()
        startAlerts()
    }

    /// 起各家的接入：有会话文件的 Agent 的运行时现在起，没有的（OpenCode）随它的索引起（`index(_:connected:)`）。
    private func startRuntimes() {
        do {
            for (agent, runtime) in runtimes where !runtimeIndexes(agent) { try runtime.start() }
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        follow { await self.indexAgents() }
    }

    /// 读出各 Agent 的接入状态，装过而内容不同的静默升级；失败报告一次。
    private func refreshAgentIntegrations() async {
        do {
            try await agents.refresh()
        } catch where !Task.isCancelled {
            reportIssue(.piBridgeUnavailable(String(localized: "CuePad 写给 Agent 的技能或扩展没能升级：\(error.localizedDescription)")))
        } catch {}
    }

    /// 系统唤醒后立即同步：睡眠期间的推送可能没收到。
    func startWakeSync() {
        follow { [wakeNotifications] in
            for await _ in wakeNotifications.notifications(named: NSWorkspace.didWakeNotification) { await self.syncNow() }
        }
    }

    /// 退出收尾。主线程上的部分（后台任务、Pi 连接、全局快捷键）在这里同步做完；返回的等待只涉及不在主线程上的组件
    /// （远程投送执行器、同步），依次停止、整体最多等 `limit`，自身不需要主线程：退出可能发生在主线程被占住时
    /// （在主线程上的任务里调用 terminate，系统在嵌套的事件循环里等回复，主线程上排队的任务轮不到）。
    /// 卡住的组件不拦着退出，记一条日志指出是哪个；等待的结果是它的名字，按时结束为 nil。
    func beginShutdown(within limit: Duration = .seconds(2)) -> @Sendable () async -> String? {
        cancelBackgroundWork()
        let hosted = runtimes.values.map { $0.stop() }
        let hostedExit: @Sendable () async -> Void = { for exit in hosted { await exit() } }
        hooks.stop()
        pi.stop()
        hotkey.unregister()
        // 离线这一条一开始收尾就写、就传，不排在别的组件停下之后：前面的步骤耗尽上限时它也已写下；停同步前等它传完
        let signingOff = Task.detached { [presence] in await presence.signOff() }
        let leaving = Task.detached { [viewer] in await viewer?.signOff() }
        let stopExecutor = executor.beginStop(), stopCue = cue.stop(), sync = sync
        let log = Logger(subsystem: AppIdentity.id, category: "shutdown")
        return { @concurrent in
            let late = await ShutdownSteps.run([
                ("远程投送执行器", stopExecutor),
                ("Cue", stopCue),
                ("这台 Mac 离线的记录", { await signingOff.value }),
                ("这台 Mac 离开会话的记录", { await leaving.value }),
                ("同步", { await sync?.stop() }),
                ("后台托管的 Agent", hostedExit),
            ], within: limit)
            if let late { log.error("退出收尾：\(late, privacy: .public) 没在 \(limit, privacy: .public) 内结束，已放行退出") }
            return late
        }
    }

    /// Cue：本机能用的运行时、按设置值班、通知（点开去哪见 `AlertCenter`）。
    private func startCue() {
        follow(reporting: { .piBridgeUnavailable(String(localized: "Cue 没能值班：\(String(describing: $0))")) }) { try await self.cue.follow() }
        follow(reporting: { .piBridgeUnavailable(String(localized: "Cue 的通知没能开始：\(String(describing: $0))")) }) { try await self.cue.followNotifications() }
    }

    // MARK: 全局快捷键

    /// 启动时注册存着的快捷键；没注册上记成启动问题，设置里换一个。
    func register(_ hotkey: GlobalHotkey) {
        do {
            try hotkey.registerSaved()
        } catch {
            reportIssue(.globalShortcutUnavailable(String(localized: "\(hotkey.label)（\(ShortcutText.display(hotkey.accelerator))）：\(String(describing: error))")))
        }
    }

    // MARK: Agent 会话历史

    /// 索引器取检查点：Store 读失败要报告（该文件不再写回）并从头读；没有或失效的检查点也是从头读。
    /// 不经主线程：回填时每个文件都来取一次，主线程同时在画界面。
    nonisolated func loadHistoryStart(for file: URL) async -> PiHistoryStart? {
        do {
            return try await historyStore.start(for: file)
        } catch {
            await reportIssue(.piHistoryUnavailable(String(localized: "读取 \(file.path) 的检查点失败：\(String(describing: error))")))
            return nil
        }
    }

    /// 每家哪些会话归 CuePad 管（`PiHistoryScope`），随接入（`AgentStatus.isConnected`，与设置里的开关同一个含义）换：接入了的是全部，
    /// 没接入的只有这台 Mac 托管过的会话（托管的会话没接入也开得出，`AgentProbe`）。索引按它回填，各家的接入按它接终端里的会话；
    /// 检测出没接入（关掉开关，或 CuePad 的文件被删了）时先删掉范围外会话的本机索引。会话的同步记录与对话不动。
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

    /// 没有会话文件的 Agent（OpenCode）由它的运行时连着它的服务建索引。
    private func runtimeIndexes(_ agent: AgentKind) -> Bool { paths.sessionsDirectory(of: agent) == nil }

    /// 建一家的索引，直到任务取消：有会话文件的读文件，其余接入期间起它的运行时、取消时停掉。
    private func index(_ agent: AgentKind, connected: Bool) async {
        if let indexer = PiHistoryIndexer(
            agent: agent, paths: paths, transcriptWindow: PiHistoryPersistence.transcriptWindow, files: store.files,
            start: { [weak self] file in await self?.loadHistoryStart(for: file) }) {
            let scope = connected ? .all : await hostedScope(of: agent)
            runtimes[agent]?.follow(scope)
            return await consumePiHistory(indexer.events(following: pi.sessionFiles, scope: scope), agent: agent)
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

    /// 没接入的 Agent 回填的范围：这台 Mac 托管过的会话；读不出来就只跟在线的。
    private func hostedScope(of agent: AgentKind) async -> PiHistoryScope {
        do {
            return try await historyStore.hostedScope(of: agent)
        } catch {
            reportIssue(.piHistoryUnavailable(String(localized: "读取 \(agent.name) 托管过的会话失败：\(String(describing: error))")))
            return .sessions([])
        }
    }

    /// 首次回填时攒够这么多个文件写一次（一个事务、一次变更通知）；回填完成后文件一变就写。
    static let backfillBatch = 200

    /// 消费一个 Agent 的历史索引事件：先落检查点再写会话行；读到的也交给这家的接入（会话状态有要从文件里得知的，`AgentRuntime.read`）。
    func consumePiHistory(_ events: AsyncStream<PiHistoryEvent>, agent: AgentKind) async {
        await historyStore.beginBackfill()
        var pending: [PiHistoryUpdate] = []
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

    /// 激活会话所在终端，尽量精确到标签页；精度与原因见返回值。
    func jumpToTerminal(_ id: CuePi.PiSession.ID) async throws -> PiJumpResult {
        guard let session = pi.session(id: id) else { throw PiBridgeError.unknownSession(id) }
        return await terminal.jump(to: session)
    }
}

/// 依次执行的收尾步骤，整体有时限。
nonisolated enum ShutdownSteps {
    /// 按顺序执行；全部结束返回 nil。超过 `limit` 时不再等，返回正在执行的那一步的名字（其后的步骤不执行，进程随即退出）。
    @concurrent
    static func run(_ steps: [(name: String, run: @Sendable () async -> Void)], within limit: Duration) async -> String? {
        let (outcomes, outcome) = AsyncStream<String?>.makeStream()
        let current = Mutex<String?>(steps.first?.name)  // 计时器可能先于第一步开始就到点
        let work = Task {
            for step in steps where !Task.isCancelled {
                current.withLock { $0 = step.name }
                await step.run()
            }
            outcome.yield(nil)
        }
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            outcome.yield(current.withLock { $0 })
        }
        var first = outcomes.makeAsyncIterator()
        let late = await first.next() ?? nil
        timer.cancel()
        if late != nil { work.cancel() }
        return late
    }
}
#endif
