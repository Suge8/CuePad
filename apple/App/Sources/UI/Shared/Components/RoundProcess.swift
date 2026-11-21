import CueStore
import SwiftUI

struct RoundProcess: View {
    let tools: ChatMessage.Tools?
    let ending: Ending
    let session: SessionState
    var message: UUID?
    var landed: Date?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatStay) private var stay
    @State private var toggled: Bool?
    @State private var key = UUID()
    @State private var settled = false

    nonisolated enum Ending: Equatable {
        case took(String)
        case speaking
        case running

        static let speakingShown = SessionShown(state: .known(.thinking)).speaking(true)
    }

    var body: some View {
        let process = Chat.process(tools)
        if let process, let tools, tools.steps > 0 {
            let fresh = !settled && landed.map { $0.timeIntervalSinceNow > -Self.landing } ?? false
            let expanded = !tools.items.isEmpty && (toggled ?? (message == nil || fresh || DebugHooks.preset.toolsOpen))
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    stay?(key, !expanded)
                    withAnimation(motion) { toggled = !expanded }
                } label: { header(process, open: tools.items.isEmpty ? nil : expanded) }
                    .buttonStyle(PressStyle(.inline))
                    .allowsHitTesting(!tools.items.isEmpty)
                    .accessibilityLabel(spoken(process))
                    .accessibilityExpanded(tools.items.isEmpty ? nil : expanded)
                    #if os(macOS)
                    .help(process.spoken.visible)
                    #endif
                VStack(alignment: .leading, spacing: 0) {
                    if !tools.images.isEmpty {
                        NoteThread {
                            ChatImages(hashes: tools.images, alignment: .leading, side: Self.imageSide, perRow: Self.imageRow, rows: expanded ? nil : 1)
                                .padding(.vertical, Spacing.hair)
                        }
                    }
                    if expanded {
                        NoteThread { list(tools) }
                    } else if ending == .running, let said = tools.items.last(where: { $0.kind == .said }) {
                        NoteThread { SaidRow(text: said.target, lines: 3) }
                    }
                }
                .padding(.horizontal, Self.hoverRoom).clipped().padding(.horizontal, -Self.hoverRoom)
                recached(process)
            }
            .task {
                guard fresh, (try? await Task.sleep(for: Self.beat)) != nil else { return }
                withAnimation(motion) { settled = true }
            }
            .onDisappear { if toggled == true { stay?(key, false) } }
        } else {
            recached(process)
        }
    }

    @ViewBuilder private func recached(_ process: Chat.Process?) -> some View {
        if let recached = process?.recached {
            NoteLine { Image(.failure).foregroundStyle(palette.waiting) } label: { Text(recached).foregroundStyle(palette.ink3) }
        }
    }

    private var motion: Animation? { Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) }

    private static let hoverRoom = Spacing.item
    private static let imageSide: CGFloat = 64
    private static let imageRow = 4
    private static let landing: TimeInterval = 5
    private static let beat: Duration = .milliseconds(400)

    private func spoken(_ process: Chat.Process) -> String {
        let end: String? = switch ending {
        case .took(let took): took
        case .speaking: Ending.speakingShown.label
        case .running: nil
        }
        return [process.spoken.spoken, end].compactMap { $0 }.joined(separator: "，")
    }

    private func header(_ process: Chat.Process, open: Bool?) -> some View {
        NoteLine(open: open) {
            switch ending {
            case .took, .running: Image(.tool).imageScale(.small)
            case .speaking: StateDot(shown: Ending.speakingShown, size: 6)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                switch ending {
                case .took(let took): Text(took).fixedSize()
                case .speaking: DoingLine(text: Ending.speakingShown.label).lineLimit(1)
                case .running: EmptyView()
                }
                ForEach(process.counts, id: \.kind) { count in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.hair) {
                        Image(Self.icon(count.kind)).font(Typography.caption2)
                        Text(verbatim: "\(count.count)")
                    }
                    .fixedSize().foregroundStyle(palette.ink3)
                }
                if let steps = process.steps { Text(steps).fixedSize().foregroundStyle(palette.ink3) }
            }
        }
    }

    @ViewBuilder private func list(_ tools: ChatMessage.Tools) -> some View {
        ForEach(Array(tools.items.enumerated()), id: \.offset) { index, item in row(item, at: index) }
        let listed = tools.items.count { $0.kind != .said }
        if tools.steps > listed {
            Text("另有 \(tools.steps - listed) 步未列出").font(Typography.caption).foregroundStyle(palette.ink3).noteGlyph(.indent)
        }
    }

    @ViewBuilder private func row(_ item: ChatMessage.Tools.Item, at index: Int) -> some View {
        if item.kind == .said {
            SaidRow(text: item.target, lines: 3)
        } else {
            StepRow(item: item, session: session, message: message, index: index)
        }
    }

    static func icon(_ kind: ChatMessage.Tools.Kind) -> Icon {
        switch kind {
        case .edit: .editFile
        case .command: .terminal
        case .read: .looked
        case .search: .search
        case .said: .said
        case .other, .talk, .start, .add, .done, .stop, .ask, .leave, .schedule: .tool
        }
    }
}

extension View {
    func accessibilityExpanded(_ open: Bool?) -> some View {
        accessibilityValue(open.map { $0 ? Text("已展开") : Text("已收起") } ?? Text(verbatim: ""))
    }
}

struct DisclosureChevron: View {
    let open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.expand).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            .rotationEffect(.degrees(open ? 180 : 0))
            .readerHidden(true)
    }
}

struct ToolRow<Status: View>: View {
    let icon: Icon
    let target: Text
    let truncation: Text.TruncationMode
    @ViewBuilder let status: Status
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            Image(icon)
                .font(Typography.caption2).foregroundStyle(palette.ink3)
                .readerHidden(true).noteGlyph()
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    target.font(Typography.codeNote).foregroundStyle(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                }
            } else {
                target.font(Typography.codeNote).foregroundStyle(palette.ink3)
                    .lineLimit(1).truncationMode(truncation)
                Spacer(minLength: Spacing.tight)
                status
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SaidRow: View {
    let text: String
    var lines: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            Image(RoundProcess.icon(.said)).font(Typography.caption2).foregroundStyle(palette.ink3)
                .readerHidden(true).noteGlyph()
            let said = Text(text).font(Typography.caption).foregroundStyle(palette.ink2).lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lines == nil { said.fixedSize(horizontal: false, vertical: true).selectable() } else { said }
        }
        .padding(.vertical, Spacing.hair)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}
