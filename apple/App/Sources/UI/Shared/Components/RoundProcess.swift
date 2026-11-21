import CueStore
import SwiftUI

/// 做完的几步与说过的话来自会话文件（`Recap.pendingTools`）；此刻在做的那一步来自会话状态（`detail`），由对话末尾的角色说（`LiveFigure`），这里不列。
/// Mac 上正在说的话出字时（`SessionShown.speaking`）这一块是草稿的标题，说的话就是下面的草稿，不再列一遍。
/// 工具结果里有图时，标题行下面挂着这一轮的图（`ChatImages`），点开全屏看：用户看得到 Agent 看到的，Agent 不必为了给人看再发一遍。
struct RoundProcess: View {
    let tools: ChatMessage.Tools?
    let ending: Ending
    let session: SessionState
    /// 做完的一轮是哪条回答（别的设备点开一步时请 Mac 写在它上面，`StepRow`）；在跑的一轮为 nil。
    var message: UUID?
    @Environment(\.palette) private var palette
    @State private var open = DebugHooks.preset.toolsOpen

    nonisolated enum Ending: Equatable {
        case took(String)
        /// Mac 上正在出字：这一块是草稿的标题。
        case speaking
        /// 在跑，此刻在做的由对话末尾的角色说（`LiveFigure`）：这里只列做过的几步，不再写一遍。
        case running

        static let speakingShown = SessionShown(state: .known(.thinking)).speaking(true)
    }

    var body: some View {
        let process = Chat.process(tools)
        if let process, let tools, tools.steps > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Fold(open: $open, toggles: !tools.items.isEmpty) {
                    header(process, open: tools.items.isEmpty ? nil : open)
                        .accessibilityElement(children: .ignore).accessibilityLabel(spoken(process))
                        #if os(macOS)
                        .help(process.spoken.visible)
                        #endif
                } content: {
                    if !tools.images.isEmpty {
                        NoteThread {
                            ChatImages(hashes: tools.images, alignment: .leading, side: Self.imageSide, perRow: Self.imageRow, rows: open ? nil : 1)
                                .padding(.vertical, Spacing.hair)
                        }
                    }
                    if open {
                        NoteThread { list(tools) }
                    } else if ending == .running, let said = tools.items.last(where: { $0.kind == .said }) {
                        NoteThread { SaidRow(text: said.target, lines: 3) }
                    }
                }
                recached(process)
            }
        } else {
            recached(process)
        }
    }

    @ViewBuilder private func recached(_ process: Chat.Process?) -> some View {
        if let recached = process?.recached {
            NoteLine { Image(.failure).foregroundStyle(palette.waiting) } label: { Text(recached).foregroundStyle(palette.ink3) }
        }
    }

    private static let imageSide: CGFloat = 64
    /// 手机最窄的对话列放得下的一排，三端同一个数。
    private static let imageRow = 4

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
                        Text(verbatim: "\(count.count)").contentTransition(.numericText(value: Double(count.count)))
                    }
                    .fixedSize().foregroundStyle(palette.ink3).transition(.opacity)
                }
                if let steps = process.steps { Text(steps).fixedSize().foregroundStyle(palette.ink3).contentTransition(.numericText()) }
            }
            .animation(Motion.nudge, value: process.counts.map(\.count))
            .animation(Motion.nudge, value: process.steps)
        }
    }

    @ViewBuilder private func list(_ tools: ChatMessage.Tools) -> some View {
        ForEach(Chat.rows(tools.items, settled: message != nil), id: \.self) { row in
            switch row {
            case .step(let index): step(tools.items[index], at: index)
            case .looks(let range): LooksRow(range: range, items: tools.items, session: session, message: message)
            }
        }
        let listed = tools.items.count { $0.kind != .said }
        if tools.steps > listed {
            Text("另有 \(tools.steps - listed) 步未列出").font(Typography.caption).foregroundStyle(palette.ink3).noteGlyph(.indent)
        }
    }

    @ViewBuilder private func step(_ item: ChatMessage.Tools.Item, at index: Int) -> some View {
        if item.kind == .said {
            SaidRow(text: item.target, lines: 3)
        } else {
            StepRow(item: item, session: session, message: message, index: index)
        }
    }

    /// 会话里的几类；Cue 的动作只在 Cue 页的经过里（`CueTrace.icon`），会话里没有。
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

private struct LooksRow: View {
    let range: Range<Int>
    let items: [ChatMessage.Tools.Item]
    let session: SessionState
    let message: UUID?
    @Environment(\.palette) private var palette
    @State private var open = false

    var body: some View {
        let looks = items[range], counts = Chat.looks(looks), failed = looks.count(where: \.failed)
        Fold(open: $open) {
            HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
                Image(RoundProcess.icon(counts.max { $0.count < $1.count }?.kind ?? .other))
                    .font(Typography.caption2).foregroundStyle(palette.ink3).readerHidden(true).noteGlyph()
                Text(Dotted(counts.map(\.spoken)).visible).font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1)
                if failed > 0 { Text("\(failed) 失败").font(Typography.caption).foregroundStyle(palette.failure).fixedSize() }
                DisclosureChevron(open: open)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
        } content: {
            if open {
                NoteThread {
                    ForEach(Array(range), id: \.self) { index in StepRow(item: items[index], session: session, message: message, index: index) }
                }
            }
        }
    }
}

extension View {
    func accessibilityExpanded(_ open: Bool?) -> some View {
        accessibilityValue(open.map { $0 ? Text("已展开") : Text("已收起") } ?? Text(verbatim: ""))
    }
}

struct ToolRow<Status: View>: View {
    let icon: Icon
    let target: Text
    let truncation: Text.TruncationMode
    var wraps = false
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
                    .lineLimit(wraps ? nil : 1).truncationMode(truncation)
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
