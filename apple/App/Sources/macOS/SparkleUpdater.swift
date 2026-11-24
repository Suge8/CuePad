#if os(macOS)
import Sparkle

/// Sparkle 自动下载（Info.plist 的 `SUAutomaticallyUpdate`），下好后由我们接手装的时机（`willInstallUpdateOnQuit` 返回 true），它自己的窗不弹；
/// 装不了静默的（要管理员密码等）走"温和提醒"：它不弹窗，交给 `UpdateService` 显示更新钮，点了才开它的窗。
final class SparkleUpdater: NSObject, AppUpdater, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    weak var events: UpdaterEvents?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    private var updater: SPUUpdater { controller.updater }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var checking: Bool { updater.sessionInProgress }

    func checkInBackground() { updater.checkForUpdatesInBackground() }

    func showUpdate() { controller.checkForUpdates(nil) }

    private static func version(_ item: SUAppcastItem) -> AppVersion { AppVersion(short: item.displayVersionString, build: item.versionString) }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        events?.checked(.found(Self.version(item)))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        events?.checked(.latest)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // 没有新版也走这里（SUNoUpdateError），已由 updaterDidNotFindUpdate 答过
        guard (error as NSError).code != Int(SUError.noUpdateError.rawValue) else { return }
        events?.checked(.failed(error.localizedDescription))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        events?.ready(Self.version(item), install: immediateInstallHandler)
        return true
    }

    /// 要重启装的路都经过这里（更新钮、等着时现在就装、Sparkle 窗里点的安装）；退出时顺带装的那一种不重启，不经过这里。
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard events?.relaunching(Self.version(item), install: installHandler) == true else { return false }
        // 收起 Sparkle 的"准备安装"窗（从它的窗点进来时才有）：它关不掉，按钮已经点过、不再起作用；等待与"现在就装"在更新钮里
        controller.userDriver.dismissUpdateInstallation()
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { events?.needsConfirm(Self.version(update)) }
    }

    func standardUserDriverWillFinishUpdateSession() {
        events?.confirmed()
    }
}
#endif
