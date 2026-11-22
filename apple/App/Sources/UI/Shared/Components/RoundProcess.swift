import CueStore
import SwiftUI

/// 一轮的过程：顶上一行写这一轮用了多久、做了多少；中途说的话照回答的样子连着往下排，不夹工具行。
/// 点开那一行，两句话之间做的步骤在原处插回，先后一目了然。做完的一轮摆在回答上面；在跑的一轮接在对话末尾，
/// Mac 上正在说的那句（`draft`）跟在最后。只往末尾长：正在说的那句落进过程、回答落进对话都在原处换下，不挪位置。
/// 一轮里最新的那段话与前面说过的隔开一档（`apart`）：做完的是回答，在跑的是正在说的或刚说完的那句。
/// 隔开的总是最新那段，它落进过程、落成回答时间距不变，读着的那段不跳
struct RoundProcess: View {
    let tools: ChatMessage.Tools?
    var took: String?
    var draft: String?
    let session: SessionState
    var message: UUID?
    var fadesIn = true
    @Environment(\.palette) private var palette
    @State private var open = DebugHooks.preset.toolsOpen

    var body: some View {
        let items = tools?.items ?? [], process = Chat.process(tools)
        let parts = Chat.parts(items).filter { if case .steps = $0 { open } else { true } }
        let said = items.indices.filter { items[$0].kind == .said }
        let newest = message == nil && draft == nil && said.count > 1 ? said.last : nil
        if process != nil || !parts.isEmpty || draft != nil {
            VStack(alignment: .leading, spacing: Spacing.item) {
                if let process { summary(process, items: items) }
                ForEach(parts) { part in
                    switch part {
                    case .said(let index):
                        SaidText(text: items[index].target, session: session)
                            .padding(.top, index == newest ? Self.apart : 0)
                            .transition(fadesIn ? .entry : .identity)
                    case .steps(let range): NoteThread { list(items[range]) }.transition(.opacity)
                    }
                }
                if let draft {
                    MarkdownText(source: draft).equatable()
                        .padding(.top, said.isEmpty || message != nil ? 0 : Self.apart)
                        .transition(.asymmetric(insertion: .entry, removal: .identity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.nudge, value: newest)
        }
    }

    @ViewBuilder private func summary(_ process: Chat.Process, items: [ChatMessage.Tools.Item]) -> some View {
        if let tools, tools.steps > 0 {
            let listed = items.contains { $0.kind != .said }
            Fold(open: $open, toggles: listed) {
                header(process, open: listed ? open : nil)
                    .accessibilityElement(children: .ignore).accessibilityLabel(Dotted(process.spoken.parts + [took]).spoken)
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
            }
        }
        if let recached = process.recached {
            NoteLine { Image(.failure).foregroundStyle(palette.waiting) } label: { Text(recached).foregroundStyle(palette.ink3) }
        }
    }

    static let apart = Spacing.block - Spacing.item

    private static let imageSide: CGFloat = 64
    private static let imageRow = 4

    private func header(_ process: Chat.Process, open: Bool?) -> some View {
        NoteLine(open: open) {
            Image(.tool).imageScale(.small)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                if let took { Text(took).fixedSize() }
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

    @ViewBuilder private func list(_ items: ArraySlice<ChatMessage.Tools.Item>) -> some View {
        ForEach(Chat.rows(items, settled: message != nil), id: \.self) { row in
            switch row {
            case .step(let index): StepRow(item: items[index], session: session, message: message, index: index)
            case .looks(let range): LooksRow(range: range, items: items, session: session, message: message)
            }
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

private struct SaidText: View {
    let text: String
    let session: SessionState

    var body: some View {
        MarkdownText(source: text).equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .contextMenu { MessageActions(text: text, kind: .reply, session: session) }
    }
}

private struct LooksRow: View {
    let range: Range<Int>
    let items: ArraySlice<ChatMessage.Tools.Item>
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
