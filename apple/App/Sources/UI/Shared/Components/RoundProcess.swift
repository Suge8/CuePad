import CueStore
import SwiftUI

/// 一轮的经过（会话页；Cue 页的是 `CueTrace`）：做完的回答上方、在跑的这一轮在对话末尾，同一个样子——一行旁注（`NoteLine`），不是一块：
/// - 标题行："跑了 12 步 · 改了 3 个文件"（`PiChat.processLine`），做完的接用时，在跑的接此刻的状态。
///   做完的收起时只有这一行；点它就地展开整份清单（挂在细线下，`NoteThread`；改动、出错都在原位，出错标胭脂），再点收起。
/// - 没调过工具的一轮不画：做完的、正在说话的都没有这一行；只有在跑、还没说话时是一行此刻在做的（流光）。
/// - 在跑时细线下是它最近说的那段话（收着时；展开的清单里本来就有）与正在跑的那一步（会话状态里的当前动作），实时展开：
///   话至多三行，那一步至多两行、文字有流光。做完的几步与说过的话来自会话文件（`PiRecap.pendingTools`），
///   正在跑的来自会话状态（`detail`），两者不重叠。
///   Mac 上正在说的话出字时（`PiShown.speaking`）这一块是草稿的标题，说的话就是下面的草稿，不再列一遍。
/// 清单是注脚：小一档的字、次要墨色；调用每条一行，图标、等宽的文件路径或命令、状态——改文件写 +行数 −行数，失败的只把"失败"两个字标胭脂，
/// 不显示工具输出；中途说的话按先后夹在调用之间，正常字形、至多三行。
/// 在跑的与做完后的同一种排法、同样高（同样的步骤时）：Mac 上正在说的话落库时原位换下，这一块不跳（`SessionDraft`）。
struct RoundProcess: View {
    let tools: PiChatMessage.Tools?
    let ending: Ending
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.toolsOpen

    nonisolated enum Ending: Equatable {
        /// 做完了：用时（`PiChat.took`）
        case took(String)
        /// 在跑：状态标按 `shown`；`doing` 是此刻在做的。有 `step`（那一步的图标）时它是正在跑的那一步、单列一行；
        /// 没有时（正在说话、等子代理）只写在标题行末
        case live(PiShown, doing: String, step: Icon?)

        /// 正在说话（Mac 上逐字长出的草稿上方）：状态标是在说话，标题行末写状态词。
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
                if expanded {
                    NoteThread {
                        list(tools)
                        if case .live(_, let doing, let step?) = ending { liveStep(doing, icon: step) }
                    }
                } else if case .live(let shown, let doing, let step) = ending {
                    // 它最近说的那段
                    let said = shown.speaking ? nil : tools.items.last { $0.kind == .said }
                    if said != nil || step != nil {
                        NoteThread {
                            if let said { SaidRow(text: said.target, lines: 3) }
                            if let step { liveStep(doing, icon: step) }
                        }
                    }
                }
            }
            .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
        } else if case .live(let shown, let doing, _) = ending, !shown.speaking {
            // 还没调过工具：此刻在做的（在想、只说了话），一行：对话末尾只给它留一行（`ChatLiveSlot`）
            NoteLine { PiStateDot(shown: shown, size: 6) } label: { Text(doing).lineLimit(1).shimmering() }
                .accessibilityElement(children: .ignore).accessibilityLabel(doing)
        }
    }

    /// 读屏读的一句：经过与结尾（用时或此刻在做的）。
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
            Text(line).lineLimit(1).layoutPriority(-1)
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

    /// 展开的整份清单，按先后。
    @ViewBuilder private func list(_ tools: PiChatMessage.Tools) -> some View {
        ForEach(Array(tools.items.enumerated()), id: \.offset) { _, item in row(item) }
        let listed = tools.items.count { $0.kind != .said }
        if tools.steps > listed {
            Text("另有 \(tools.steps - listed) 步未列出").font(Typography.caption).foregroundStyle(palette.ink3).padding(.leading, 19)
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

    /// 正在跑的那一步：与清单同一种行，文字是会话状态里的当前动作、带流光，放得下两行。
    private func liveStep(_ doing: String, icon: Icon) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(icon).font(Typography.caption2).foregroundStyle(palette.ink3)
                .noteGlyph().accessibilityHidden(true)
            Text(doing).font(Typography.codeNote).lineLimit(2).truncationMode(.middle).shimmering()
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    /// 正在跑的那一步的图标，按会话状态里的工具名（`PiSessionState.detail` 的前一截）：与清单里同一类同一个图标；还没调工具（在想）是省略号。
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
        case .other, .talk, .start, .add, .done, .stop, .ask, .leave: .tool
        }
    }
}

extension View {
    /// 就地展开、收起的那一行给读屏的值；`nil` 是这一行展不开。
    func accessibilityExpanded(_ open: Bool?) -> some View {
        accessibilityValue(open.map { $0 ? Text("已展开") : Text("已收起") } ?? Text(verbatim: ""))
    }
}

/// 就地展开的那一行末尾的箭头（工具清单、子代理汇总、Cue 的运行情况共用）：收着朝下，展开转过来朝上。
struct DisclosureChevron: View {
    let open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.expand).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            .rotationEffect(.degrees(open ? 180 : 0))
            .accessibilityHidden(true)
    }
}

/// 工具清单的一行（会话里回答注脚的清单、Cue 的运行情况共用）：图标、等宽小字的目标、右侧状态。
struct ToolRow<Status: View>: View {
    let icon: Icon
    let target: Text
    let truncation: Text.TruncationMode
    @ViewBuilder let status: Status
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Note.spacing) {
            Image(icon)
                .font(Typography.caption2).foregroundStyle(palette.ink3)
                .noteGlyph().accessibilityHidden(true)
            target.font(Typography.codeNote).foregroundStyle(palette.ink3)
                .lineLimit(1).truncationMode(truncation)
            Spacer(minLength: 4)
            status
        }
        .accessibilityElement(children: .combine)
    }
}

/// 旁注清单里说的一段话（一轮经过里中途说的）：与清单同一列的图标位，正常字形、次要墨色；
/// `lines` 是至多几行，nil 是全文（可选中）。
struct SaidRow: View {
    let text: String
    var lines: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            Image(RoundProcess.icon(.said)).font(Typography.caption2).foregroundStyle(palette.ink3)
                .noteGlyph().accessibilityHidden(true)
            let said = Text(text).font(Typography.caption).foregroundStyle(palette.ink2).lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 全文的可以挑字；收成几行的在按钮里（点它回到对话里那一条），不开
            if lines == nil { said.fixedSize(horizontal: false, vertical: true).selectable() } else { said }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}
