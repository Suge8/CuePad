import CueStore
import SwiftUI

/// 一轮的过程：中途说的话照回答的样子留在原处，两句话之间的步骤各收成一行，点开看是哪几步。
/// 做完的一轮摆在回答上面，`took`（这一轮用了多久）挂在最后一行步骤上；在跑的一轮接在对话末尾，Mac 上正在说的那句（`draft`）跟在最后。
/// 只往末尾长：缓存失效的提示在最前，正在说的那句落进过程、回答落进对话都在原处换下，不挪位置
struct RoundProcess: View {
    let tools: ChatMessage.Tools?
    var took: String?
    var draft: String?
    let session: SessionState
    var message: UUID?
    var fadesIn = true
    @Environment(\.palette) private var palette

    var body: some View {
        let items = tools?.items ?? [], parts = Chat.parts(items), recached = Chat.recached(tools)
        let closing = parts.last { if case .steps = $0 { true } else { false } }
        if !parts.isEmpty || recached != nil || draft != nil {
            VStack(alignment: .leading, spacing: Spacing.item) {
                if let recached {
                    NoteLine { Image(.failure).foregroundStyle(palette.waiting) } label: { Text(recached).foregroundStyle(palette.ink3) }
                }
                ForEach(parts) { part in
                    switch part {
                    case .said(let index):
                        SaidText(text: items[index].target, session: session).transition(arrival)
                    case .steps(let range):
                        StepsRow(
                            items: items[range], took: part == closing ? took : nil, unlisted: part == closing ? tools.map(Chat.unlisted) ?? 0 : 0,
                            session: session, message: message)
                        .transition(arrival)
                    }
                }
                if let draft { MarkdownText(source: draft).equatable().transition(.asymmetric(insertion: .entry, removal: .identity)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var arrival: AnyTransition { fadesIn ? .entry : .identity }

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

private struct StepsRow: View {
    let items: ArraySlice<ChatMessage.Tools.Item>
    let took: String?
    let unlisted: Int
    let session: SessionState
    let message: UUID?
    @Environment(\.palette) private var palette
    @State private var open = DebugHooks.preset.toolsOpen

    var body: some View {
        let counts = Chat.counts(items), images = Self.images(items)
        Fold(open: $open) {
            header(counts)
                .accessibilityElement(children: .ignore).accessibilityLabel(spoken(counts))
                #if os(macOS)
                .help(Dotted(counts.isEmpty ? [total] : counts.map(\.spoken)).visible)
                #endif
        } content: {
            if !images.isEmpty {
                NoteThread {
                    ChatImages(hashes: images, alignment: .leading, side: Self.imageSide, perRow: Self.imageRow, rows: open ? nil : 1)
                        .padding(.vertical, Spacing.hair)
                }
            }
            if open { NoteThread { list } }
        }
    }

    private static let imageSide: CGFloat = 64
    private static let imageRow = 4

    private static func images(_ items: ArraySlice<ChatMessage.Tools.Item>) -> [String] {
        var seen = Set<String>()
        return items.flatMap { $0.images ?? [] }.filter { seen.insert($0).inserted }
    }

    private var total: String { String(localized: "共 \(items.count) 步") }

    private func spoken(_ counts: [Chat.Count]) -> String {
        Dotted((counts.isEmpty ? [total] : counts.map(\.spoken)) + [took]).spoken
    }

    private func header(_ counts: [Chat.Count]) -> some View {
        NoteLine(open: open) {
            Image(.tool).imageScale(.small)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                if let took { Text(took).fixedSize() }
                ForEach(counts, id: \.kind) { count in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.hair) {
                        Image(RoundProcess.icon(count.kind)).font(Typography.caption2)
                        Text(verbatim: "\(count.count)").contentTransition(.numericText(value: Double(count.count)))
                    }
                    .fixedSize().foregroundStyle(palette.ink3).transition(.opacity)
                }
                if counts.isEmpty { Text(total).fixedSize().foregroundStyle(palette.ink3) }
            }
            .animation(Motion.nudge, value: counts.map(\.count))
        }
    }

    @ViewBuilder private var list: some View {
        ForEach(Chat.rows(items, settled: message != nil), id: \.self) { row in
            switch row {
            case .step(let index): StepRow(item: items[index], session: session, message: message, index: index)
            case .looks(let range): LooksRow(range: range, items: items, session: session, message: message)
            }
        }
        if unlisted > 0 {
            Text("另有 \(unlisted) 步未列出").font(Typography.caption).foregroundStyle(palette.ink3).noteGlyph(.indent)
        }
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
