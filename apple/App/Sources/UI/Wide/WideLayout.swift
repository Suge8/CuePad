import SwiftUI

struct WideMetrics {
    static let session: CGFloat = 390
    #if os(macOS)
    static let cue: CGFloat = 388
    #else
    static let cue: CGFloat = 400
    #endif

    static let previewWidth = LivePreview.phoneWidth + 2 * Spacing.page

    enum Kind: Hashable {
        case page, session, preview, card

        var narrowest: CGFloat { self == .preview ? WideMetrics.previewWidth : WideMetrics.session }
        var weight: CGFloat { self == .preview ? 1.5 : 1 }
    }

    /// 排版与滑动认的"同一块"：页换了一页仍是那一块（原地换，不滑不淡），会话、灵感各认各的。
    enum Piece: Hashable {
        case page, session(UUID), card(UUID), preview

        init(_ pane: WideNavigation.Pane) {
            switch pane {
            case .page: self = .page
            case .session(let route): self = .session(route.id)
            case .card(let id): self = .card(id)
            case .preview: self = .preview
            }
        }

        var kind: Kind {
            switch self {
            case .page: .page
            case .session: .session
            case .card: .card
            case .preview: .preview
            }
        }
    }

    struct Shares: Equatable {
        private var stored: [[Kind]: [CGFloat]] = [:]

        func fractions(_ kinds: [Kind]) -> [CGFloat] {
            if let kept = stored[kinds] { return kept }
            let total = kinds.map(\.weight).reduce(0, +)
            return kinds.map { $0.weight / total }
        }

        mutating func set(_ fractions: [CGFloat]?, for kinds: [Kind]) { stored[kinds] = fractions }
    }

    let rail: CGFloat
    let railFits: Bool
    let main: CGFloat
    let cue: CGFloat
    /// 看得见的几块，从左到右（窗口窄时最右的藏起，至少一块）。
    let order: [Piece]
    let widths: [CGFloat]
    let fill: Bool
    let cueFits: Bool
    let room: Int

    var kinds: [Kind] { order.map(\.kind) }
    var split: Bool { order.count > 1 }
    func narrowest(_ index: Int) -> CGFloat { order[index].kind.narrowest }
    var leading: CGFloat { widths[0] }

    func origin(_ index: Int, window: CGFloat) -> CGFloat {
        guard index < widths.count else { return window }
        guard index > 0 else { return rail }
        if fill { return order[index] == .preview ? 0 : window }
        return edge(after: index - 1)
    }

    func edge(after index: Int) -> CGFloat { rail + widths.prefix(index + 1).reduce(0, +) }

    func width(_ index: Int) -> CGFloat {
        guard index < widths.count else { return (main / 2).rounded() }
        return fill && index > 0 ? main : widths[index]
    }

    struct Shape: Equatable {
        let rail: CGFloat
        let cue: CGFloat
        var panes = 1
        var fill = false
        var order: [Piece] = []
    }

    var shape: Shape { Shape(rail: rail, cue: cue, panes: widths.count, fill: fill, order: order) }

    var spans: [Piece: Span] {
        Dictionary(order.indices.map { (order[$0], Span(origin: origin($0, window: .infinity), width: width($0))) }) { first, _ in first }
    }

    struct Span: Equatable {
        let origin: CGFloat
        let width: CGFloat
    }

    struct Fits: Equatable {
        let rail: Bool
        let cue: Bool
        let width: CGFloat
    }

    let window: CGFloat
    var fits: Fits { Fits(rail: railFits, cue: cueFits, width: window) }

    init(width: CGFloat, workspace: Workspace, navigation: WideNavigation? = nil) {
        window = width
        let wanted = (navigation?.panes ?? workspace.panes).map(Piece.init)
        var shown = max(1, wanted.count)
        while shown > 1, wanted.prefix(shown).map(\.kind.narrowest).reduce(0, +) > width { shown -= 1 }
        order = wanted.isEmpty ? [.page] : Array(wanted.prefix(shown))
        let kinds = order.map(\.kind)
        fill = kinds.contains(.preview) && workspace.liveFill != nil
        let narrowest = kinds.map(\.narrowest).reduce(0, +)
        railFits = width >= Self.railThreshold(kinds)
        rail = workspace.sidebarOpen && railFits && !fill ? Chrome.rail : 0
        cueFits = shown == 1 && width >= rail + narrowest + Self.cue
        cue = workspace.services.settings.cueOpen && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
        widths = Self.widths(main: main, kinds: kinds, fractions: workspace.paneShares.fractions(kinds))
        let spare = max(0, width - narrowest)
        room = min(WideNavigation.maxPanes, shown + Int(spare / Self.session))
    }

    static func widths(main: CGFloat, kinds: [Kind], fractions: [CGFloat]) -> [CGFloat] {
        let narrowest = kinds.map(\.narrowest)
        var widths = zip(fractions, narrowest).map { max($1, ($0 * main).rounded()) }
        var excess = widths.reduce(0, +) - main
        for index in widths.indices.reversed() where excess > 0 {
            let give = min(excess, widths[index] - narrowest[index])
            widths[index] -= give
            excess -= give
        }
        for index in widths.indices.dropFirst().reversed() where excess > 0 {
            let give = min(excess, widths[index])
            widths[index] -= give
            excess -= give
        }
        widths[widths.count - 1] += max(0, main - widths.reduce(0, +))
        return widths
    }

    static func boardLead(_ inset: EdgeInsets) -> CGFloat { inset.leading + Spacing.item + Chrome.control - BoardCardMetrics.inset }

    /// 这几块都摆得下、会话条也放得下的最窄窗口。
    static func railThreshold(_ kinds: [Kind]) -> CGFloat { Chrome.rail + kinds.map(\.narrowest).reduce(0, +) }

    static func railThreshold(of panes: [WideNavigation.Pane]) -> CGFloat { railThreshold(panes.map { Piece($0).kind }) }
}

extension View {
    func reportsWideFits(_ sizes: WideMetrics, to workspace: Workspace) -> some View {
        onChange(of: sizes.fits, initial: true) { _, fits in workspace.fit(fits) }
    }
}

extension View {
    func reachesWindowBottom() -> some View { ignoresSafeArea(.container, edges: .bottom) }
}
