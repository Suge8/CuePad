#if os(macOS)
import AppKit
import CueStore
import CueSync

/// Mac 主窗口与提示：开着哪个会话页（`ViewerKeeper` 写下，提示据此定发不发）、点开的通知去哪。
extension Workspace {
    /// App 在前台、主窗口可见：此刻看得到内容区的这一页。
    private var isInFront: Bool { NSApp.isActive && services.windowShell?.isVisible == true }

    /// 此刻开着的会话页（这台 Mac 开着哪个会话，`ViewerKeeper`）。
    var openSession: ViewerKeeper.Page? {
        guard isInFront, case .session(let route) = page else { return nil }
        return ViewerKeeper.Page(id: route.id, sessionID: route.sessionID)
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
