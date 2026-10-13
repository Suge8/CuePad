#if os(macOS)
import CuePi
import Observation

/// 接入 Pi（扩展、skill 与 `cuepad` 命令行链接，见 `PiIntegration`）的唯一状态：除了"拒绝过"这一个偏好，全部从磁盘读出。
/// 首次检测到可用的 Pi 时问一次（`needsConsent`）：同意调 `connect()`，拒绝调 `decline()`，之后不再问、什么都不写。
/// 已接入时 `refresh()` 发现哪样旧了或缺了（App 更新后随包版本变了、App 移动后链接指向旧位置）就静默修复，不再询问。
@Observable
final class PiIntegrationManager {
    private(set) var status: PiIntegrationStatus?
    /// 用户 shell 的 PATH 里是否有链接所在目录；外层 nil 是还没查，内层 nil 是读不出来。
    private(set) var linkDirectoryInShellPath: Bool??
    /// 隔离运行（开发构建）而 Pi 目录或链接目录是缺省的真实位置时为 false：不询问、不修复、不能接入（`PiPaths.isExplicit`）。
    let isEnabled: Bool

    @ObservationIgnored let installer: PiIntegration
    @ObservationIgnored private let settings: AppSettings

    init(installer: PiIntegration, settings: AppSettings, isEnabled: Bool) {
        self.installer = installer
        self.settings = settings
        self.isEnabled = isEnabled
    }

    /// Pi 可用（版本够新），没接入，没有位置被别人占着，且用户没有拒绝过。
    var needsConsent: Bool {
        guard isEnabled, let status, status.pi.isSupported, !status.isConnected, status.blocked.isEmpty else { return false }
        return !settings.piConnectDeclined
    }

    /// 读状态；已接入而有哪样不是最新时静默修复。修复失败抛错，状态仍反映磁盘上的样子。
    func refresh() async throws {
        status = await installer.status()
        guard isEnabled, let status, status.pi.isSupported, status.isConnected, !status.isCurrent else { return }
        try await write { try await installer.install() }
    }

    /// 接入（或修复）三样；已运行的会话在终端里 /reload 才会加载新扩展。
    func connect() async throws {
        try await write { try await installer.install() }
        settings.piConnectDeclined = false
    }

    /// 移除 CuePad 写的三样，并记为拒绝过：之后不再询问、不再修复。
    func disconnect() async throws {
        try await write { try await installer.uninstall() }
        settings.piConnectDeclined = true
    }

    func decline() {
        settings.piConnectDeclined = true
    }

    func checkShellPath() async {
        linkDirectoryInShellPath = .some(await installer.linkDirectoryInShellPath())
    }

    private func write(_ action: () async throws -> Void) async throws {
        do {
            try await action()
        } catch {
            status = await installer.status()
            throw error
        }
        status = await installer.status()
    }
}
#endif
