import SwiftUI

/// 跳过去之后指出是哪几个会话（`Workspace.spotlight`，Cue 页的待回复提示经 `openReplies` 设）：看板等你列与会话列表里它们的卡亮一下，
/// 所在的列、行、列表先把第一张滑进视野。卡在页到了前台才开始亮（`pageActive`）：不在屏上的页里动画不画，起了也白起。
/// 只认 `until` 之前到前台、建出来的卡：之后的（滚进来的懒加载行、换过去的另一段）不亮，离开再回来也不重亮。
struct Spotlight: Equatable {
    let sessions: Set<String>
    let until: Date

    /// 点下之后多久内到前台的卡还亮：盖住换 tab、建页、读列表，忙的时候也来得及；亮起来之后整段照放（`Motion.spotlightOut`）。
    private static let landing: TimeInterval = 2

    init(_ sessions: some Sequence<String>) {
        self.sessions = Set(sessions)
        until = .now + Self.landing
    }

    func lights(_ session: String) -> Bool { Date.now < until && sessions.contains(session) }

    /// 把这一格滑进视野：每次指出是一次新要求。
    func reveal(_ target: some Hashable) -> Reveal { Reveal(target: target, request: until) }
}

/// 滚动区要滑到的那一格（看板的列与行、会话列表）。`request` 分开前后两次要求：同一格再要一次也滑。
struct Reveal: Equatable {
    let target: AnyHashable
    var request: Date?
}

extension PiSessionList {
    /// 列表里第一个被指出的会话（置顶在前；待回复歇着，都在"现在"里）。
    func reveal(_ spotlight: Spotlight?) -> Reveal? {
        guard let spotlight, let item = (pinned + now).first(where: { spotlight.lights($0.state.sessionID) }) else { return nil }
        return spotlight.reveal(item.id)
    }
}

extension View {
    /// 这个会话被指出时卡上亮一下：靛青的选中底加一圈边（同"选中是一块底"），盖在卡上、不改排版，淡入、停一会、淡掉（`Motion.spotlightOut`）。
    func spotlit(_ session: String, cornerRadius: CGFloat) -> some View { modifier(SpotlightMark(session: session, radius: cornerRadius)) }
}

private struct SpotlightMark: ViewModifier {
    let session: String
    let radius: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var lit = false

    private static let ring: CGFloat = 1.5

    func body(content: Content) -> some View {
        content
            .overlay {
                if lit {
                    let shape = RoundedRectangle(cornerRadius: radius)
                    shape.fill(palette.selection)
                        .overlay(shape.strokeBorder(palette.signature, lineWidth: Self.ring))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .task(id: active ? workspace.spotlight : nil) {
                guard workspace.spotlight?.lights(session) == true else { return }
                withAnimation(Motion.fade) { lit = true } completion: {
                    withAnimation(Motion.spotlightOut) { lit = false }
                }
            }
    }
}
