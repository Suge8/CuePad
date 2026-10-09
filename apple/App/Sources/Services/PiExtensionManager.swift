#if os(macOS)
import CuePi
import Observation

/// Pi 扩展的检测、首次安装与升级。同意只在首次安装时问一次：界面读 `needsConsent` 决定是否询问，用户同意调 `install()`，
/// 拒绝调 `decline()`（之后不再询问、不安装）。已装的是 CuePad 的扩展时，`refresh()` 发现它与随包版本不同就静默升级，
/// 不再询问——随包版本只在 App 更新后变化，而 App 启动时就会 `refresh()`。
@MainActor @Observable
final class PiExtensionManager {
    private(set) var status: PiExtensionStatus?

    @ObservationIgnored private let installer: PiExtensionInstaller
    @ObservationIgnored private let settings: AppSettings

    init(installer: PiExtensionInstaller, settings: AppSettings) {
        self.installer = installer
        self.settings = settings
    }

    /// Pi 可用（版本够新），还没装过扩展，且用户没有拒绝过。
    var needsConsent: Bool {
        guard let status, status.pi.isSupported, status.file == .missing else { return false }
        return !settings.piExtensionDeclined
    }

    /// 检测状态；已装的是旧版（或内容不同的）CuePad 扩展时升级到随包版本。升级失败抛错，状态仍反映磁盘上的旧版。
    func refresh() async throws {
        status = await installer.status()
        guard let status, status.pi.isSupported, case .outdated = status.file else { return }
        try await install()
    }

    /// 新装或升级（原子写入）；已运行的会话在终端里 /reload 才会加载新扩展。
    func install() async throws {
        try await installer.install()
        status = await installer.status()
    }

    func decline() {
        settings.piExtensionDeclined = true
    }
}
#endif
