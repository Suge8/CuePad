#if os(macOS)
import CueDispatch
import Observation

/// 辅助功能授权（通用投送的前提）。权限归属 CuePad.app；授权发生在系统设置里，
/// 所以应用每次回到前台时重新读取。
@MainActor @Observable
final class AccessibilityAccess {
    private(set) var isTrusted: Bool
    @ObservationIgnored private let query: @Sendable () -> Bool

    init(isTrusted query: @escaping @Sendable () -> Bool) {
        self.query = query
        isTrusted = query()
    }

    func refresh() {
        isTrusted = query()
    }

    /// 未授权时弹出系统引导。
    func request() {
        isTrusted = Accessibility.requestTrust()
    }
}
#endif
