#if os(macOS)
import Sparkle

/// Sparkle 标准更新流程：EdDSA 校验、后台定期检查、增量更新。更新源与公钥在 Info.plist（SUFeedURL、SUPublicEDKey）。
final class SparkleUpdater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
