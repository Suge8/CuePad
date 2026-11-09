import CueStore
import SwiftUI

/// 做完的几步与说过的话来自会话文件（`PiRecap.pendingTools`），正在跑的来自会话状态（`detail`），两者不重叠。
/// Mac 上正在说的话出字时（`PiShown.speaking`）这一块是草稿的标题，说的话就是下面的草稿，不再列一遍。
/// 工具结果里有图时，标题行下面总挂着这一轮的图（收着、展开都在，`ChatImages`），点开全屏看：用户看得到 Agent 看到的，Agent 不必为了给人看再发一遍。
/// 在跑的与做完后的同一种排法、同样高（同样的步骤时）：Mac 上正在说的话落库时原位换下，这一块不跳（`SessionDraft`）。
struct RoundProcess: View {
    let tools: PiChatMessage.Tools?
    let ending: Ending
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var expanded = DebugHooks.preset.toolsOpen

    nonisolated enum Ending: Equatable {
        case took(String)
        case live(PiShown, doing: String, step: Icon?)

        static var speaking: Ending {
            let shown = PiShown(state: .known(.thinking)).speaking(true)
            return .live(shown, doing: shown.label, step: nil)
        }
    }

    var body: some View {
        if let line = PiChat.processLine(tools), let tools {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: { header(line) }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(spoken(line))
                    .accessibilityExpanded(expanded)
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
            }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: expanded)
        } else if case .live(let shown, let doing, _) = ending, !shown.speaking {
            // 还没调过工具：此刻在做的（在想、只说了话），一行：对话末尾只给它留一行（`ChatLiveSlot`）
            NoteLine { PiStateDot(shown: shown, size: 6) } label: { Text(doing).lineLimit(1).shimmering() }
                .accessibilityElement(children: .ignore).accessibilityLabel(doing)
        }
    }

    private static let imageSide: CGFloat = 88

    private func spoken(_ line: Dotted) -> String {
        let end: String? = switch ending {
        case .took(let took): took
        case .live(_, let doing, _): doing
        }
        return [line.spoken, end].compactMap { $0 }.joined(separator: "，")
    }

    private func header(_ line: Dotted) -> some View {
        NoteLine(open: expanded) {
            switch ending {
            case .took: Image(.tool).imageScale(.small)
            case .live(let shown, _, _): PiStateDot(shown: shown, size: 6)
            }
        } label: {
            Text(line).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize).layoutPriority(-1)
            switch ending {
            case .took(let took):
                Dot()
                Text(took).fixedSize()
            case .live(_, let doing, nil):
                Dot()
                Text(doing).lineLimit(1).shimmering()
            case .live:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func list(_ tools: PiChatMessage.Tools) -> some View {
        ForEach(Array(tools.items.enumerated()), id: \.offset) { _, item in row(item) }
        let listed = tools.items.count { $0.kind != .said }
        if tools.steps > listed {
            Text("另有 \(tools.steps - listed) 步未列出").font(Typography.caption).foregroundStyle(palette.ink3).noteGlyph(.indent)
        }
    }

    @ViewBuilder private func row(_ item: PiChatMessage.Tools.Item) -> some View {
        if item.kind == .said {
            SaidRow(text: item.target, lines: 3)
        } else {
            ToolRow(icon: Self.icon(item.kind), target: Text(item.target), truncation: item.kind == .command ? .tail : .middle) { status(item) }
        }
    }


    @ViewBuilder private func status(_ item: PiChatMessage.Tools.Item) -> some View {
        if item.failed {
            Text("失败").font(Typography.caption).foregroundStyle(palette.failure)
        } else if item.added != nil || item.removed != nil {
            Text(PiChat.diffLabel(added: item.added, removed: item.removed)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
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
    static func icon(_ kind: PiChatMessage.Tools.Kind) -> Icon {
        switch kind {
        case .edit: .editFile
        case .command: .terminal
        case .read: .readFile
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
