#if os(macOS)
import CuePi
import CueStore
import Foundation
import Observation

/// 自动更新器（生产是 `SparkleUpdater`）。
protocol AppUpdater: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    /// 后台查一次：有更新照常提示，没有不出声。
    func checkForUpdatesInBackground()
    /// 更新装好前、App 要退出重启时问一次（菜单的检查与后台的定期检查都到这里）：返回 true 就先不重启，之后调用交来的 `install` 接着装。
    var postponeRelaunch: ((_ install: @escaping () -> Void) -> Bool)? { get set }
}

/// 界面与菜单用的自动更新入口。没有更新器（不是正式版签名：本机构建与测试不去读真实的更新源与偏好）时全部无操作。
///
/// 装更新要重启 CuePad。托管的会话有的撑得过重启（`AgentRuntime.hostedSessionsOutliveApp`：托管的 Pi 脱离 App，新版经桥认回），
/// 有的随 App 退出被收掉（靠管道连着 App 的 Claude Code、Codex，CuePad 拉起的 OpenCode 服务）。所以更新要重启时，只要还有撑不过的
/// 托管会话在干活或等你确认（`PiWorkState.hasPendingWork`，含等子代理），就先不重启，等它们都空下来再自动装；等着时可以现在就装。
@Observable
final class UpdateService {
    @ObservationIgnored private let updater: (any AppUpdater)?
    @ObservationIgnored private let bridge: PiBridge
    @ObservationIgnored private let runtimes: [AgentKind: any AgentRuntime]
    /// 推迟中的更新接着装下去的办法（更新器交来的）；没在等时为 nil。
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// 推迟中的更新还在等几个后台会话做完；没在等时为 nil。
    private(set) var waitingFor: Int?

    init(updater: (any AppUpdater)?, bridge: PiBridge, runtimes: [AgentKind: any AgentRuntime]) {
        self.updater = updater
        self.bridge = bridge
        self.runtimes = runtimes
        updater?.postponeRelaunch = { [weak self] install in self?.postpone(install) ?? false }
    }

    var isAvailable: Bool { updater != nil }
    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    var waitingNote: String? { waitingFor.map { String(localized: "等 \($0) 个 Agent 做完再装") } }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// 别的设备已用新版、这台停下同步时（`SyncStatus.outdated`）当场查一次，不等定期检查（默认一天一次）。
    func checkInBackground() {
        updater?.checkForUpdatesInBackground()
    }

    /// 不等了，现在就装（会结束还在跑的后台会话）。
    func installNow() {
        guard let install else { return }
        self.install = nil
        waitingFor = nil
        watcher?.cancel()
        watcher = nil
        install()
    }

    /// 重启会打断的：撑不过重启的托管会话里还有活的
    private var busy: Int {
        bridge.sessions.count { $0.hosted && $0.state.hasPendingWork && runtimes[$0.agent]?.hostedSessionsOutliveApp != true }
    }

    private func postpone(_ install: @escaping () -> Void) -> Bool {
        let busy = busy
        guard busy > 0 else { return false }
        self.install = install
        waitingFor = busy
        let changes = bridge.changes()
        watcher = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                let busy = self.busy
                if busy == 0 { return self.installNow() }
                self.waitingFor = busy
            }
        }
        return true
    }
}
#endif
