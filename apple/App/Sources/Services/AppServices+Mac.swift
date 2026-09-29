#if os(macOS)
import CueDispatch
import CuePi
import Foundation

/// macOS 壳层与后台服务的生命周期：启动、停止、全局快捷键、Pi 历史索引、终端跳转。
extension AppServices {
    /// 幂等。窗口与 `windowShell` 就绪后调用。
    func start() {
        guard tasks.isEmpty else { return }
        applySavedShortcut()
        accessibility.refresh()
        do {
            try pi.start()
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        let checkpoints = historyStore
        let indexer = PiHistoryIndexer(root: paths.sessionsDirectory) { await checkpoints.checkpoint(for: $0) }
        tasks = [
            Task { await importLegacyIfNeeded() },
            Task { await piExtension.refresh() },
            Task { await consumePiHistory(indexer.events()) },
        ]
    }

    /// 真正退出时释放：后台任务、Pi 连接、全局快捷键。
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        pi.stop()
        hotkey.unregister()
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

    /// 消费历史索引事件：先落检查点再写会话行。
    func consumePiHistory(_ events: AsyncStream<PiHistoryEvent>) async {
        for await event in events {
            switch event {
            case .updated(let update):
                do {
                    try await historyStore.persist(update)
                } catch {
                    Self.log.error("Pi 历史索引写入失败：\(String(describing: error), privacy: .public)")
                }
            case .backfillFinished:
                finishPiHistoryBackfill()
            }
        }
    }

    /// 激活会话所在终端，尽量精确到标签页；精度与原因见返回值。
    func jumpToTerminal(_ id: CuePi.PiSession.ID) async throws -> PiJumpResult {
        guard let session = pi.sessions.first(where: { $0.id == id }) else { throw PiBridgeError.unknownSession(id) }
        return await terminal.jump(to: session)
    }

    // MARK: 通用投送目标

    func runningApps() -> [AppInfo] { channels.runningApps() }
    func lastFrontmostApp() -> AppInfo? { channels.lastFrontmost() }
}
#endif
