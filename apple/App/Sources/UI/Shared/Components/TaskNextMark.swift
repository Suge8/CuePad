import CueStore
import SwiftUI

struct TaskNextMark: View {
    let next: TaskNext
    var primary = false
    var retry = false
    @Environment(\.rowHovered) private var lit
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: follow) { label }
            .buttonStyle(PressStyle(.mark))
            .help(retry ? String(localized: "重试") : next.starts ? help : String(localized: "\(next.speech)，\(help)"))
            .accessibilityLabel(retry ? String(localized: "重试") : next.speech)
            .accessibilityHint(help)
    }

    private var label: some View {
        HStack(spacing: Spacing.glyph) {
            switch next {
            case .agent(let shown, let session):
                StateDot(shown: shown, size: Self.dot).relaySpot(session: session.sessionID, row: .task)
                if shown.speaksOnTask { Text(shown.label).foregroundStyle(shown.labelTint(palette)) }
            case .start where primary:
                Image(retry ? .retry : .start).font(Self.glyph).foregroundStyle(palette.onAction)
                    .frame(width: Self.disc, height: Self.disc)
                    .background(palette.action, in: .circle)
            case .start:
                Image(.start).font(Self.glyph).foregroundStyle(palette.ink)
                    .frame(width: Self.disc, height: Self.disc)
                    .background(lit ? palette.track : palette.fill, in: .circle)
            }
        }
        .font(TaskMetrics.caption)
        .foregroundStyle(palette.ink2)
        .lineLimit(1).fixedSize()
        .frame(minWidth: Self.target, minHeight: Self.target, alignment: edge)
        .contentShape(.rect)
        .animation(Motion.fade, value: lit)
    }

    #if os(macOS)
    private var edge: Alignment { .leading }
    private static let dot: CGFloat = 6
    static let glyph = Glyph.mark
    static let target: CGFloat = 20
    static let disc: CGFloat = 20
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private var edge: Alignment { !primary && (sizeClass == .regular || typeSize.isAccessibilitySize) ? .leading : .trailing }
    private static let dot: CGFloat = 7
    static let glyph = Typography.caption2.weight(.bold)
    static let target: CGFloat = TaskMetrics.chipTarget
    static let disc: CGFloat = 28
    #endif

    private var help: String {
        switch next {
        case .agent: String(localized: "打开这件事的 Agent 会话")
        case .start: startHelp
        }
    }

    private var startHelp: String {
        #if os(macOS)
        if case .start(let leaf) = next, let choice = workspace.localAgents.flatMap({ workspace.services.settings.launchChoice(on: $0, in: leaf.projectID) }),
           let agent = choice.agent {
            let brain = [agent.name, choice.current?.displayName].compactMap(\.self).joined(separator: " ")
            return String(localized: "把任务的正文交给 Agent，开始做。开新会话时用 \(brain)，点开任务可以换")
        }
        #endif
        return String(localized: "把任务的正文交给 Agent，开始做")
    }

    private func follow() { workspace.follow(next) }
}
