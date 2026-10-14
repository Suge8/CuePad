#if os(macOS)
import AppKit
import CueStore
import CueSync

/// Mac 主窗口与提示：你在不在看、点开去哪（`AlertCenter` 发通知、系统交来前台呈现、点开的通知都问这里）。
extension Workspace {
    /// 只有这一处定：在看是 CuePad 在前台、主窗口在屏幕上，且正看着那个会话或 Agent 页（会话的提示；Agent 页上那一行已经在变），
    /// 或 Cue 页（Cue 的，`AppServices.cueViewers`）。在看时什么都不发；其余一律是系统通知。
    func isWatching(_ route: AlertRoute) -> Bool {
        guard NSApp.isActive, services.windowShell?.isVisible == true else { return false }
        return switch route {
        case .cue: services.cueViewers > 0
        case .session(let tap): page == .agent || page == .session(tap.sessionState)
        }
    }

    /// 点开的 Agent 通知：打开那个会话的整页。通知只带会话记录 id，Mac 的会话页按 Pi 的会话 id 认（桥上的在线会话）：从记录里取；
    /// 记录已经没了（会话删了）就不去。
    func open(alert tap: PiAlertTap) async {
        do {
            if let item = try await services.store.piSessionPage(PiSessionQuery(id: tap.sessionState)).items.first {
                show(.session(item.state.sessionID))
            }
        } catch {
            fail(error)
        }
    }
}
#endif
