#if os(macOS)
import Foundation
import Observation

/// 界面与菜单用的自动更新入口。没有更新器（隔离模式：开发与验收不能去读真实的更新源与偏好）时全部无操作。
@Observable
final class UpdateService {
    @ObservationIgnored private let updater: SparkleUpdater?

    init(updater: SparkleUpdater?) {
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
