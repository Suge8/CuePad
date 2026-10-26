#if os(macOS)
import Sparkle

/// Sparkle 标准更新流程：EdDSA 校验、后台定期检查。更新源与公钥在 Info.plist（SUFeedURL、SUPublicEDKey）。
final class SparkleUpdater: NSObject, AppUpdater, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    var postponeRelaunch: ((_ install: @escaping () -> Void) -> Bool)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    /// 要重启装更新的路都经过这里（你在更新窗里点"安装并重新启动"，不论那次检查是菜单点的还是后台定期的；自动下载后的立即安装）；
    /// 退出时顺带装的那一种不重启，不经过这里。每次更新只问一次。
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard postponeRelaunch?(installHandler) == true else { return false }
        // 收起 Sparkle 的"准备安装"窗：它关不掉，按钮已经点过、不再起作用；等待与"现在就装"在设置的更新那一行与菜单里
        controller.userDriver.dismissUpdateInstallation()
        return true
    }
}
#endif
