#if os(macOS)
import CuePi
import Observation

/// Pi 扩展的检测与安装。写入 Pi 的扩展目录前必须征得用户同意：界面读 `needsConsent` 决定是否询问，
/// 用户同意调 `install()`，拒绝调 `decline()`（同一随包版本不再询问，扩展升级后再问）。
@MainActor @Observable
final class PiExtensionManager {
    private(set) var status: PiExtensionStatus?

    @ObservationIgnored private let installer: PiExtensionInstaller
    @ObservationIgnored private let settings: AppSettings

    init(installer: PiExtensionInstaller, settings: AppSettings) {
        self.installer = installer
        self.settings = settings
    }

    /// Pi 可用（版本够新），扩展缺失或已过期，且用户没有对当前随包版本拒绝过。
    var needsConsent: Bool {
        guard let status, status.pi.isSupported else { return false }
        switch status.file {
        case .missing, .outdated: return settings.piExtensionDeclinedVersion != PiExtensionBundle.version
        case .current, .foreign: return false
        }
    }

    func refresh() async {
        status = await installer.status()
    }

    /// 新装或升级；升级后已运行的会话要重启才会加载新扩展。
    func install() async throws {
        try await installer.install()
        await refresh()
    }

    func decline() {
        settings.piExtensionDeclinedVersion = PiExtensionBundle.version
    }
}
#endif
