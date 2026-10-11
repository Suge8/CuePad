#if os(macOS)
import AppKit
import CuePi
import Foundation
import os
import Synchronization

/// macOS 壳层与后台服务的生命周期：启动、停止、全局快捷键、Pi 历史索引、终端跳转。
extension AppServices {
    /// 幂等。窗口与 `windowShell` 就绪后调用。
    func start() {
        guard !tasks.isRunning else { return }
        applySavedShortcut()
        if !location.isIsolated { diagnostics.start() }
        let piChanges = pi.changes() // 先订阅再启动桥：启动时扫到的会话不能漏
        host.start()
        do {
            try pi.start()
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        let indexer = PiHistoryIndexer(root: paths.sessionsDirectory, transcriptWindow: PiHistoryPersistence.transcriptWindow) { [weak self] file in
            await self?.loadPiCheckpoint(for: file)
        }
        follow(reporting: { .piBridgeUnavailable("CuePad 的 Pi 扩展没能升级：\($0.localizedDescription)") }) { try await self.piIntegration.refresh() }
        follow { await self.consumePiHistory(indexer.events()) }
        follow { await self.historyStore.keepPruned() }
        follow(reporting: { .syncUnavailable("Agent 状态没能写入同步记录：\($0)") }) {
            try await self.resetPiState()
            try await self.consumePiChanges(piChanges)
        }
        follow(reporting: { .syncUnavailable("远程投送执行器没能启动：\($0)") }) { try await self.executor.start() }
        follow(reporting: { .syncUnavailable("目录绑定没能同步给手机：\($0)") }) { try await self.startDirectoryBindings() }
        // CKSyncEngine 靠静默推送得知别的设备的改动；macOS 要显式注册远程通知（iOS 由 PiAlertCenter 注册）。
        if sync != nil { NSApplication.shared.registerForRemoteNotifications() }
        startSync()
        startLiveSessions()
    }

    /// 系统唤醒后立即同步：睡眠期间的推送可能没收到。
    func startWakeSync() {
        follow { [wakeNotifications] in
            for await _ in wakeNotifications.notifications(named: NSWorkspace.didWakeNotification) { await self.syncNow() }
        }
    }

    /// 退出收尾。主线程上的部分（后台任务、Pi 连接、全局快捷键）在这里同步做完；返回的等待只涉及不在主线程上的组件
    /// （远程投送执行器、同步引擎），依次停止、整体最多等 `limit`，自身不需要主线程：退出可能发生在主线程被占住时
    /// （在主线程上的任务里调用 terminate，系统在嵌套的事件循环里等回复，主线程上排队的任务轮不到）。
    /// 卡住的组件不拦着退出，记一条日志指出是哪个；等待的结果是它的名字，按时结束为 nil。
    func beginShutdown(within limit: Duration = .seconds(2)) -> @Sendable () async -> String? {
        cancelBackgroundWork()
        let hostedExit = host.closeAll()
        pi.stop()
        hotkey.unregister()
        let stopExecutor = executor.beginStop(), sync = sync
        let log = Logger(subsystem: Self.bundleID, category: "shutdown")
        return { @concurrent in
            let late = await ShutdownSteps.run([
                ("远程投送执行器", stopExecutor),
                ("同步引擎", { await sync?.stop() }),
                ("后台托管的 Pi", hostedExit),
            ], within: limit)
            if let late { log.error("退出收尾：\(late, privacy: .public) 没在 \(limit, privacy: .public) 内结束，已放行退出") }
            return late
        }
    }

    /// 在主线程空闲时收尾（测试与不经 terminate 的场合）。
    @discardableResult
    func stop(within limit: Duration = .seconds(2)) async -> String? {
        await beginShutdown(within: limit)()
    }

    // MARK: 全局快捷键

    func applySavedShortcut() {
        do {
            guard let shortcut = Shortcut(accelerator: settings.globalShortcut) else {
                throw HotkeyError.unsupportedAccelerator(settings.globalShortcut)
            }
            try hotkey.register(shortcut)
        } catch {
            reportIssue(.globalShortcutUnavailable("\(error)"))
        }
    }

    /// 注册新快捷键，成功后才写入设置；失败时旧快捷键与设置都不变，错误交给设置界面展示。
    func setGlobalShortcut(_ accelerator: String) throws {
        guard let shortcut = Shortcut(accelerator: accelerator), let normalized = shortcut.accelerator else {
            throw HotkeyError.unsupportedAccelerator(accelerator)
        }
        try hotkey.register(shortcut)
        settings.globalShortcut = normalized
    }

    // MARK: Pi

    /// 索引器取检查点：Store 读失败要报告（该文件不再写回）并从头读；没有或失效的检查点也是从头读。
    /// 不经主线程：回填时每个文件都来取一次，主线程同时在画界面。
    nonisolated func loadPiCheckpoint(for file: URL) async -> PiHistoryCheckpoint? {
        do {
            return try await historyStore.checkpoint(for: file)
        } catch {
            await reportIssue(.piHistoryUnavailable("读取 \(file.path) 的检查点失败：\(error)"))
            return nil
        }
    }

    /// 首次回填时攒够这么多个文件写一次（一个事务、一次变更通知）；回填完成后文件一变就写。
    static let backfillBatch = 200

    /// 消费历史索引事件：先落检查点再写会话行。
    func consumePiHistory(_ events: AsyncStream<PiHistoryEvent>) async {
        await historyStore.beginBackfill()
        var pending: [PiHistoryUpdate] = []
        var backfilling = true
        func flush() async {
            guard !pending.isEmpty else { return }
            for failure in await historyStore.persist(pending) {
                reportIssue(.piHistoryUnavailable("写入 \(failure.file.path) 失败：\(failure.error)"))
            }
            pending.removeAll()
        }
        for await event in events {
            switch event {
            case .updated(let update):
                pending.append(update)
                if !backfilling || pending.count >= Self.backfillBatch { await flush() }
            case .backfillFinished(let files):
                await flush()
                backfilling = false
                do {
                    try await historyStore.retain(files)
                    try await piStateRecorder.dropUnindexedHosted()
                } catch {
                    reportIssue(.piHistoryUnavailable("清理已不存在的会话失败：\(error)"))
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
