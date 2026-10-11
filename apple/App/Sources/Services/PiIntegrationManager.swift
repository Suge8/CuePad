#if os(macOS)
import CuePi
import Observation

/// CuePad 与 Pi 的集成（扩展 + skill，一起装、一起升级）的检测、首次安装与升级。同意只在首次安装时问一次：界面读 `needsConsent` 决定是否询问，
/// 用户同意调 `install()`，拒绝调 `decline()`（之后不再询问、两样都不装）。已装的是 CuePad 写的时，`refresh()` 发现与随包版本不同
/// （含 App 被移动后 skill 里的 cuepad 路径变了）就静默升级，不再询问——随包版本只在 App 更新后变化，而 App 启动时就会 `refresh()`。
@Observable
final class PiIntegrationManager {
    private(set) var status: PiIntegrationStatus?

    @ObservationIgnored private let installer: PiIntegration
    @ObservationIgnored private let settings: AppSettings

    init(installer: PiIntegration, settings: AppSettings) {
        self.installer = installer
        self.settings = settings
    }

    /// Pi 可用（版本够新），还没装过，且用户没有拒绝过。
    var needsConsent: Bool {
        guard let status, status.pi.isSupported, status.file == .missing else { return false }
        return !settings.piExtensionDeclined
    }

    /// 检测状态；已装的是旧版（或内容不同的）CuePad 集成时升级到随包版本。升级失败抛错，状态仍反映磁盘上的旧版。
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
