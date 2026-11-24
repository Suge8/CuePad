#if os(macOS)
import CueBridge
import CueStore
import Foundation
import Observation

/// 一版更新：`build` 是构建号（Sparkle 比新旧用的、`CFBundleVersion`），`name` 是给人看的"版本（构建号）"，同 `AppServices.version`。
nonisolated struct AppVersion: Equatable, Sendable {
    let build: String
    let name: String

    init(short: String, build: String) {
        self.build = build
        name = "\(short)（\(build)）"
    }
}

/// 更新器（Sparkle）报来的事：查的结果、下好了、要你在它的窗里确认、要重启装。
protocol UpdaterEvents: AnyObject {
    func checked(_ result: UpdateCheck)
    func ready(_ version: AppVersion, install: @escaping () -> Void)
    func needsConfirm(_ version: AppVersion)
    func confirmed()
    /// 要重启装这一版：返回 true 就先不重启，之后调 `install`。
    func relaunching(_ version: AppVersion, install: @escaping () -> Void) -> Bool
}

protocol AppUpdater: AnyObject {
    var events: UpdaterEvents? { get set }
    var automaticallyChecksForUpdates: Bool { get set }
    var checking: Bool { get }
    /// 后台查一次：有新版就下载，下好报 `ready`；不弹窗。
    func checkInBackground()
    /// Sparkle 自己的更新窗：只给要你确认的那一版（`needsConfirm`）。
    func showUpdate()
}

enum UpdateCheck: Equatable {
    case found(AppVersion)
    case latest
    case failed(String)
}

/// 更新的状态只在这里。后台定期查到新版就下载，下好是 `ready`（侧栏底下出现更新钮）；点了装、或退出时 Sparkle 自己装。
/// 装要重启 CuePad：托管的 Pi 脱离 App，新版经桥认回；靠管道连着 App 的 Claude Code、Codex 与 CuePad 拉起的 OpenCode 服务随 App 退出被收掉，
/// 所以还有撑不过重启的托管会话在干活或等你确认（`WorkState.hasPendingWork`，含等子代理）时是 `waiting`，等它们都空下来再自动装，等着时可以现在就装。
/// Sparkle 装不了静默的那种（要管理员密码等）是 `confirm`，点了才开它自己的窗。
@Observable
final class UpdateService: UpdaterEvents {
    enum State: Equatable {
        case ready(AppVersion)
        case waiting(AppVersion, busy: Int)
        case confirm(AppVersion)
    }

    private(set) var state: State?
    @ObservationIgnored private let updater: (any AppUpdater)?
    @ObservationIgnored private let bridge: Bridge
    @ObservationIgnored private let runtimes: [AgentKind: any AgentRuntime]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var nudges: Task<Void, Never>?
    @ObservationIgnored private var asking: CheckedContinuation<UpdateCheck, Never>?
    static let checkNow = "\(AppIdentity.id).check-update"
    private static let installingKey = "updateInstalling"

    init(updater: (any AppUpdater)?, bridge: Bridge, runtimes: [AgentKind: any AgentRuntime], defaults: UserDefaults) {
        self.updater = updater
        self.bridge = bridge
        self.runtimes = runtimes
        self.defaults = defaults
        updater?.events = self
        guard updater != nil else { return }
        let asked = DarwinNotifications.notifications(named: Self.checkNow)
        nudges = Task { [weak self] in
            for await _ in asked { self?.updater?.checkInBackground() }
        }
    }

    isolated deinit {
        nudges?.cancel()
    }

    var isAvailable: Bool { updater != nil }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    /// 上次退出前下好或要你确认的那一版、这次已经是它了：取一次就清掉。装没成（还是旧版）也清掉，Sparkle 会再报。
    func updatedTo() -> String? {
        guard let build = defaults.string(forKey: Self.installingKey) else { return nil }
        defaults.removeObject(forKey: Self.installingKey)
        return build == Bundle.main.infoDictionary?["CFBundleVersion"] as? String ? AppServices.version : nil
    }

    /// 你点的"检查更新"：已经下好的直接答；在查就不再起一次（Sparkle 同时只跑一次，起了也不会答）。
    func check() async -> UpdateCheck? {
        guard let updater, asking == nil else { return nil }
        switch state {
        case .ready(let version), .waiting(let version, _), .confirm(let version): return .found(version)
        case nil: if updater.checking { return nil }
        }
        return await withCheckedContinuation { continuation in
            asking = continuation
            updater.checkInBackground()
        }
    }

    func checkInBackground() {
        updater?.checkInBackground()
    }

    /// 更新钮：下好的就装（会断的会话在干活则等），要确认的开 Sparkle 的窗，等着的现在就装。
    func act() {
        switch state {
        case .ready: install?()
        case .confirm: updater?.showUpdate()
        case .waiting: installNow()
        case nil: break
        }
    }

    private func installNow() {
        guard let install else { return }
        self.install = nil
        watcher?.cancel()
        watcher = nil
        install()
    }

    private var busy: Int {
        bridge.sessions.count { $0.state.hasPendingWork && runtimes[$0.agent]?.hostedSessionsOutliveApp != true }
    }

    func checked(_ result: UpdateCheck) {
        asking?.resume(returning: result)
        asking = nil
    }

    func ready(_ version: AppVersion, install: @escaping () -> Void) {
        defaults.set(version.build, forKey: Self.installingKey)
        self.install = install
        state = .ready(version)
    }

    func needsConfirm(_ version: AppVersion) {
        defaults.set(version.build, forKey: Self.installingKey)
        state = .confirm(version)
    }

    func confirmed() {
        if case .confirm = state { state = nil }
    }

    func relaunching(_ version: AppVersion, install: @escaping () -> Void) -> Bool {
        let busy = busy
        guard busy > 0 else { return false }
        self.install = install
        state = .waiting(version, busy: busy)
        let changes = bridge.changes()
        watcher = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                let busy = self.busy
                if busy == 0 { return self.installNow() }
                self.state = .waiting(version, busy: busy)
            }
        }
        return true
    }
}
#endif
