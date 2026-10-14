#if os(macOS)
import CuePi
import Foundation
import Observation

/// 自动更新器（生产是 `SparkleUpdater`）。
protocol AppUpdater: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    /// 更新装好前、App 要退出重启时问一次（菜单的检查与后台的定期检查都到这里）：返回 true 就先不重启，之后调用交来的 `install` 接着装。
    var postponeRelaunch: ((_ install: @escaping () -> Void) -> Bool)? { get set }
}

/// 界面与菜单用的自动更新入口。没有更新器（隔离模式：开发与验收不能去读真实的更新源与偏好）时全部无操作。
///
/// 装更新要重启 CuePad，会结束它在后台托管的会话（各家的接入随 App 退出收掉托管的进程，新版也可能按扩展协议收掉旧的）。所以更新要重启时，
/// 只要还有托管的会话在干活或等你确认（`PiWorkState.hasPendingWork`，含等子代理），就先不重启，等它们都空下来再自动装；
/// 等着时可以现在就装。一条规则管所有家，看的是桥上的会话，不看是哪家、扩展协议是几。
@Observable
final class UpdateService {
    @ObservationIgnored private let updater: (any AppUpdater)?
    @ObservationIgnored private let bridge: PiBridge
    /// 推迟中的更新接着装下去的办法（更新器交来的）；没在等时为 nil。
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// 推迟中的更新还在等几个后台会话做完；没在等时为 nil。
    private(set) var waitingFor: Int?

    init(updater: (any AppUpdater)?, bridge: PiBridge) {
        self.updater = updater
        self.bridge = bridge
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

    /// 更新那一行与菜单写的等待：等 N 个 Agent 做完再装。
    var waitingNote: String? { waitingFor.map { "等 \($0) 个 Agent 做完再装" } }

    func checkForUpdates() {
        updater?.checkForUpdates()
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

    private var busy: Int { bridge.sessions.count { $0.hosted && $0.state.hasPendingWork } }

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
