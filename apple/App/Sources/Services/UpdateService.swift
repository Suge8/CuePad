#if os(macOS)
import Foundation
import Observation

/// 更新器能力：生产实现是 Sparkle（`SparkleUpdater`），测试用替身。
@MainActor
protocol AppUpdater: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// 界面与菜单用的自动更新入口。没有更新器（隔离模式：开发与验收不能去读真实的更新源与偏好）时全部无操作。
@MainActor @Observable
final class UpdateService {
    @ObservationIgnored private let updater: (any AppUpdater)?

    init(updater: (any AppUpdater)?) {
        self.updater = updater
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

    func checkForUpdates() {
        updater?.checkForUpdates()
    }
}
#endif
