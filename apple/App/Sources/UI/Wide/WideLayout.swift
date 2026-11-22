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
        case session, preview, card

        init(_ pane: WideNavigation.Beside) {
            switch pane {
            case .session: self = .session
            case .preview: self = .preview
            case .card: self = .card
            }
        }

        var narrowest: CGFloat { self == .preview ? WideMetrics.previewWidth : WideMetrics.session }
        var weight: CGFloat { self == .preview ? 1.5 : 1 }
    }

    struct Shares: Equatable {
        private var stored: [[Kind]: [CGFloat]] = [:]

        func fractions(_ beside: [Kind]) -> [CGFloat] {
            if let kept = stored[beside] { return kept }
            let weights = [Kind.session.weight] + beside.map(\.weight)
            let total = weights.reduce(0, +)
            return weights.map { $0 / total }
        }

        mutating func set(_ fractions: [CGFloat]?, for beside: [Kind]) { stored[beside] = fractions }
    }

    let rail: CGFloat
    let railFits: Bool
    let main: CGFloat
    let cue: CGFloat
    let beside: [Kind]
    let widths: [CGFloat]
    let fill: Bool
    let cueFits: Bool
    let room: Int
    let order: [WideNavigation.Beside]

    var split: Bool { !beside.isEmpty }
    func narrowest(_ index: Int) -> CGFloat { index == 0 ? Self.session : beside[index - 1].narrowest }
    var leading: CGFloat { widths[0] }

    func origin(_ index: Int, window: CGFloat) -> CGFloat {
        guard index < widths.count else { return window }
        guard index > 0 else { return rail }
        if fill { return beside[index - 1] == .preview ? 0 : window }
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
        var order: [WideNavigation.Beside] = []
    }

    var shape: Shape { Shape(rail: rail, cue: cue, panes: widths.count, fill: fill, order: order) }

    var spans: [WideNavigation.Beside: Span] {
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
        let panes = navigation?.panes ?? workspace.session(in: .main).map { [.session($0)] + workspace.beside } ?? []
        let wanted = panes.dropFirst().map(Kind.init)
        var shown = wanted.count
        while shown > 0, Self.session + wanted.prefix(shown).map(\.narrowest).reduce(0, +) > width { shown -= 1 }
        beside = Array(wanted.prefix(shown))
        order = Array(panes.prefix(1 + shown))
        fill = beside.contains(.preview) && workspace.liveFill != nil
        let narrowest = Self.session + beside.map(\.narrowest).reduce(0, +)
        railFits = width >= Chrome.rail + narrowest
        rail = workspace.sidebarOpen && railFits && !fill ? Chrome.rail : 0
        cueFits = beside.isEmpty && width >= rail + narrowest + Self.cue
        cue = workspace.services.settings.cueOpen && cueFits ? Self.cue : 0
        main = max(0, width - rail - cue)
        widths = Self.widths(main: main, beside: beside, fractions: workspace.paneShares.fractions(beside))
        let spare = max(0, width - narrowest)
        room = min(WideNavigation.maxPanes, 1 + shown + Int(spare / Self.session))
    }

    static func widths(main: CGFloat, beside: [Kind], fractions: [CGFloat]) -> [CGFloat] {
        let narrowest = [session] + beside.map(\.narrowest)
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

    static func narrowestMain(split: Bool) -> CGFloat { split ? 2 * session : session }

    static func railThreshold(split: Bool) -> CGFloat { Chrome.rail + narrowestMain(split: split) }

    static func cueThreshold(split: Bool) -> CGFloat { railThreshold(split: split) + cue }
}

extension View {
    func reportsWideFits(_ sizes: WideMetrics, to workspace: Workspace) -> some View {
        onChange(of: sizes.fits, initial: true) { _, fits in workspace.fit(fits) }
    }
}

extension View {
    func reachesWindowBottom() -> some View { ignoresSafeArea(.container, edges: .bottom) }
}
