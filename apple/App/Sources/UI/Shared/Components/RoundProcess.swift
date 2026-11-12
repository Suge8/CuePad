import CueStore
import SwiftUI

/// 做完的几步与说过的话来自会话文件（`Recap.pendingTools`），正在跑的来自会话状态（`detail`），两者不重叠。
/// Mac 上正在说的话出字时（`SessionShown.speaking`）这一块是草稿的标题，说的话就是下面的草稿，不再列一遍。
/// 工具结果里有图时，标题行下面总挂着这一轮的图（收着、展开都在，`ChatImages`），点开全屏看：用户看得到 Agent 看到的，Agent 不必为了给人看再发一遍。
/// 在跑的与做完后的同一种排法、同样高（同样的步骤时，清单都开着）：Mac 上正在说的话落库时原位换下，这一块不跳（`SessionDraft`）。
/// 清单里的一步点开看里面（`StepRow`）；标题行是用时（在跑的是此刻在做的）接每类一个图标配个数，图标与清单那一类的同一个；缓存没接上的一轮在末尾另起一行写重读了多少（`Chat.process`）。
struct RoundProcess: View {
    let tools: ChatMessage.Tools?
    let ending: Ending
    let session: SessionState
    /// 做完的一轮是哪条回答（别的设备点开一步时请 Mac 写在它上面，`StepRow`）；在跑的一轮为 nil。
    var message: UUID?
    /// 在跑的与最新做完的那一轮清单开着（`ChatEntry.latest`），你发出下一句就收起；之后你点开、收起的照你的。
    var open = true
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.chatStay) private var stay
    @State private var toggled: Bool?

    nonisolated enum Ending: Equatable {
        case took(String)
        case live(SessionShown, doing: String, step: Icon?)

        static var speaking: Ending {
            let shown = SessionShown(state: .known(.thinking)).speaking(true)
            return .live(shown, doing: shown.label, step: nil)
        }
    }

    var body: some View {
        let process = Chat.process(tools)
        if let process, let tools, tools.steps > 0 {
            let expanded = !tools.items.isEmpty && (toggled ?? (open || DebugHooks.preset.toolsOpen))
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    stay?(!expanded)
                    toggled = !expanded
                } label: { header(process, open: tools.items.isEmpty ? nil : expanded) }
                    .buttonStyle(PressStyle())
                    .allowsHitTesting(!tools.items.isEmpty)
                    .accessibilityLabel(spoken(process))
                    .accessibilityExpanded(tools.items.isEmpty ? nil : expanded)
                    #if os(macOS)
                    .help(process.spoken.visible)
                    #endif
                if !tools.images.isEmpty {
                    NoteThread { ChatImages(hashes: tools.images, alignment: .leading, side: Self.imageSide).padding(.vertical, Spacing.hair) }
                }
                if expanded {
                    NoteThread {
                        list(tools)
                        if case .live(_, let doing, let step?) = ending { liveStep(doing, icon: step) }
                    }
                } else if case .live(let shown, let doing, let step) = ending {
                    let said = shown.speaking ? nil : tools.items.last { $0.kind == .said }
                    if said != nil || step != nil {
                        NoteThread {
                            if let said { SaidRow(text: said.target, lines: 3) }
                            if let step { liveStep(doing, icon: step) }
                        }
                    }
                }
                recached(process)
            }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: expanded)
            .onChange(of: open) { toggled = nil }
        } else {
            // 还没调过工具：此刻在做的（在想、只说了话），一行：对话末尾只给它留一行（`ChatLiveSlot`）
            let live: (SessionShown, String)? = if case .live(let shown, let doing, _) = ending, !shown.speaking { (shown, doing) } else { nil }
            if live != nil || process?.recached != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let (shown, doing) = live {
                        NoteLine { StateDot(shown: shown, size: 6) } label: { Text(doing).lineLimit(1).shimmering() }
                            .accessibilityElement(children: .ignore).accessibilityLabel(doing)
                    }
                    recached(process)
                }
            }
        }
    }

    @ViewBuilder private func recached(_ process: Chat.Process?) -> some View {
        if let recached = process?.recached {
            NoteLine { Image(.failure).foregroundStyle(palette.waiting) } label: { Text(recached).foregroundStyle(palette.waiting) }
        }
    }

    private static let imageSide: CGFloat = 88

    private func spoken(_ process: Chat.Process) -> String {
        let end: String? = switch ending {
        case .took(let took): took
        case .live(_, let doing, _): doing
        }
        return [process.spoken.spoken, end].compactMap { $0 }.joined(separator: "，")
    }

    private func header(_ process: Chat.Process, open: Bool?) -> some View {
        NoteLine(open: open) {
            switch ending {
            case .took: Image(.tool).imageScale(.small)
            case .live(let shown, _, _): StateDot(shown: shown, size: 6)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                switch ending {
                case .took(let took): Text(took).fixedSize()
                case .live(_, let doing, nil): Text(doing).lineLimit(1).shimmering()
                case .live: EmptyView()
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

    private func liveStep(_ doing: String, icon: Icon) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            Image(icon).font(Typography.caption2).foregroundStyle(palette.ink3)
                .readerHidden(true).noteGlyph()
            Text(doing).font(Typography.codeNote)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize).shimmering()
        }
        .padding(.bottom, Spacing.hair)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    static func icon(tool: String?) -> Icon {
        switch tool?.lowercased() {
        case nil: .pondering
        case "edit", "write": icon(.edit)
        case "bash": icon(.command)
        case "read": icon(.read)
        case "grep", "find", "glob", "ls": icon(.search)
        default: icon(.other)
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
