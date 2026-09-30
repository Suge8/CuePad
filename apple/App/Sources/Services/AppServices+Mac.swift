#if os(macOS)
import AppKit
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
        let piChanges = pi.changes() // 先订阅再启动桥：启动时扫到的会话不能漏
        do {
            try pi.start()
        } catch {
            reportIssue(.piBridgeUnavailable("\(error)"))
        }
        let indexer = PiHistoryIndexer(root: paths.sessionsDirectory) { [weak self] file in
            await self?.loadPiCheckpoint(for: file)
        }
        tasks = [
            Task { await importLegacyIfNeeded() },
            Task { await piExtension.refresh() },
            Task { await consumePiHistory(indexer.events()) },
            Task {
                do {
                    try await resetPiState()
                    try await consumePiChanges(piChanges)
                } catch {
                    reportIssue(.syncUnavailable("Pi 状态没能写入同步记录：\(error)"))
                }
            },
            Task {
                do {
                    try await startDeliveryExecutor()
                } catch {
                    reportIssue(.syncUnavailable("远程投送执行器没能启动：\(error)"))
                }
            },
        ]
        startSync()
    }

    /// 系统唤醒后立即同步：睡眠期间的推送可能没收到。
    func startWakeSync() {
        tasks.append(Task { [wakeNotifications] in
            for await _ in wakeNotifications.notifications(named: NSWorkspace.didWakeNotification) { await syncNow() }
        })
    }

    /// 真正退出时释放：后台任务、Pi 连接、全局快捷键。
    func stop() {
        cancelBackgroundWork()
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

    /// 索引器取检查点：Store 读失败要报告（该文件不再写回）并从头读；没有或失效的检查点也是从头读。
    func loadPiCheckpoint(for file: URL) async -> PiHistoryCheckpoint? {
        do {
            return try await historyStore.checkpoint(for: file)
        } catch {
            reportIssue(.piHistoryUnavailable("读取 \(file.path) 的检查点失败：\(error)"))
            return nil
        }
    }

    /// 消费历史索引事件：先落检查点再写会话行。
    func consumePiHistory(_ events: AsyncStream<PiHistoryEvent>) async {
        for await event in events {
            switch event {
            case .updated(let update):
                do {
                    try await historyStore.persist(update)
                } catch {
                    reportIssue(.piHistoryUnavailable("写入 \(update.file.path) 失败：\(error)"))
                }
            case .backfillFinished:
                break
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

    /// 已安装应用的显示名（不要求在运行）；找不到该应用时用 bundle ID 本身。
    func appName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else {
            return bundleID
        }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
        return name as? String ?? url.deletingPathExtension().lastPathComponent
    }
}
#endif
