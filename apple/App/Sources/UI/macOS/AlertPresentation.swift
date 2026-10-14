#if os(macOS)
import AppKit
import CueStore
import CueSync

/// 一条提示在 Mac 上怎么出现（`Workspace.presentation`）。
enum AlertPresentation {
    /// 你正看着它说的那一页：什么都不发。
    case watching
    /// CuePad 在前台、主窗口在屏幕上，但没在看：窗口顶上的提示条 + 声音。
    case notice
    /// 不在前台或主窗口不在屏幕上：系统横幅 + 声音。
    case banner
}

/// Mac 主窗口上的提示：怎么出现、点开去哪（`AlertCenter` 发通知、呈现与点开的通知都问这里）。
extension Workspace {
    /// 只有这一处定：在看是 CuePad 在前台、主窗口在屏幕上，且正看着那个会话或 Agent 页（会话的提示；Agent 页上那一行已经在变），
    /// 或 Cue 页（Cue 的，`AppServices.cueViewers`）。
    func presentation(of route: AlertRoute) -> AlertPresentation {
        guard NSApp.isActive, services.windowShell?.isVisible == true else { return .banner }
        let watching = switch route {
        case .cue: services.cueViewers > 0
        case .session(let tap): page == .agent || page == .session(tap.sessionState)
        }
        return watching ? .watching : .notice
    }

    /// 窗口顶上的提示条：图标是那种提示的，点它去那一页。会话记录已经没了（会话删了）就不说。
    func say(_ route: AlertRoute, text: Dotted) async {
        guard let link = await self.route(route) else { return }
        say(text, symbol: SessionAlert.symbol(route.kind), link: link, duration: Self.alertDuration)
    }

    /// 点开的 Agent 通知：打开那个会话的整页。
    func open(alert tap: PiAlertTap) async {
        if let route = await route(.session(tap)) { show(route) }
    }

    /// 通知只带会话记录 id，Mac 的会话页按 Pi 的会话 id 认（桥上的在线会话）：从记录里取。
    private func route(_ route: AlertRoute) async -> Route? {
        switch route {
        case .cue: return .cue
        case .session(let tap):
            do {
                return try await services.store.piSessionPage(PiSessionQuery(id: tap.sessionState)).items.first.map { Route.session($0.state.sessionID) }
            } catch {
                fail(error)
                return nil
            }
        }
    }
}
#endif
