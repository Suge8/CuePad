import CueStore
import SwiftUI

/// 一轮的经过（会话页）：做完的回答上方、在跑的这一轮在对话末尾，同一个样子——与代码块、表格同一套底色与圆角的一块：
/// - 标题行："跑了 12 步 · 改了 3 个文件 · 1 处出错"（`PiChat.processLine`，出错那一截标胭脂），做完的接用时，在跑的接此刻的状态。
///   有工具活动时点它就地展开整份清单、再点收起。没调过工具时只有一行：做完的"用时 8 秒"，在跑的是此刻在做的（流光）。
/// - 收起时也列出改了的文件与出错的那几步（`PiChat.pinned`）：它们不能被埋掉；多了只列前几条，其余写个数、点它展开。
/// - 在跑时最下面是正在跑的那一步（会话状态里的当前动作），实时展开：最多两行、文字有流光。已做完的几步来自会话文件
///   （`PiRecap.pendingTools`），正在跑的来自会话状态，两者不重叠。
/// 清单是注脚：小一档的等宽字、次要墨色；每条一行，图标、文件路径或命令、状态——改文件写 +行数 −行数，失败的只把"失败"两个字标胭脂；不显示工具输出。
/// 在跑的与做完后的同一种排法、同样高（同样的步骤时）：Mac 上正在说的话落库时原位换下，这一块不跳（`SessionDraft`）。
struct RoundProcess: View {
    let tools: PiChatMessage.Tools?
    let ending: Ending
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.toolsOpen

    enum Ending: Equatable {
        /// 做完了：用时（`PiChat.took`）
        case took(String)
        /// 在跑：状态标按 `shown`；`doing` 是此刻在做的。有 `step`（那一步的图标）时它是正在跑的那一步、单列一行；
        /// 没有时（正在说话、等子代理）只写在标题行末
        case live(PiShown, doing: String, step: String?)
    }

    /// 收起时最多列几条改动与出错：再多就是一份清单了，写个数、点开看。
    private static let pinLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tools {
                Button { expanded.toggle() } label: { header(PiChat.processLine(tools)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spoken(PiChat.processLine(tools)))
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                rows(tools)
                if case .live(_, let doing, let step?) = ending { liveStep(doing, symbol: step) }
            } else {
                bare.accessibilityElement(children: .ignore).accessibilityLabel(spoken(nil))
            }
        }
        .roundNoteFrame()
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
    }

    /// 读屏读的一句：经过与结尾（用时或此刻在做的）。
    private func spoken(_ line: PiChat.ProcessLine?) -> String {
        let end: String = switch ending {
        case .took(let took): line == nil ? "用时 \(took)" : took
        case .live(_, let doing, _): doing
        }
        return ([line?.steps.spoken, line?.failures, end] as [String?]).compactMap { $0 }.joined(separator: "，")
    }

    /// 没调过工具：做完的是用时，在跑的是此刻在做的。
    @ViewBuilder private var bare: some View {
        switch ending {
        case .took(let took):
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").imageScale(.small).accessibilityHidden(true)
                Text("用时 \(took)")
            }
            .roundNoteLine()
        case .live(let shown, let doing, _):
            HStack(spacing: 6) {
                PiStateDot(shown: shown, size: 6)
                Text(doing).lineLimit(2).shimmering()
            }
            .roundNoteLine()
        }
    }

    private func header(_ line: PiChat.ProcessLine) -> some View {
        HStack(spacing: 5) {
            switch ending {
            case .took: Image(systemName: "wrench.and.screwdriver").imageScale(.small).accessibilityHidden(true)
            case .live(let shown, _, _): PiStateDot(shown: shown, size: 6)
            }
            Text(line.steps).lineLimit(1).layoutPriority(-1)
            if let failures = line.failures {
                Dot()
                Text(failures).foregroundStyle(palette.failure).fixedSize()
            }
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
            DisclosureChevron(open: expanded)
        }
        .roundNoteLine()
        .contentShape(.rect)
    }

    /// 收起时是改动与出错的那几步，展开是整份清单。
    @ViewBuilder private func rows(_ tools: PiChatMessage.Tools) -> some View {
        let pinned = PiChat.pinned(tools)
        let shown = expanded ? tools.items : Array(pinned.prefix(Self.pinLimit))
        if !shown.isEmpty || expanded {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in row(item) }
                if expanded, tools.total > tools.items.count {
                    more("另有 \(tools.total - tools.items.count) 步未列出")
                } else if !expanded, pinned.count > Self.pinLimit {
                    Button { expanded = true } label: { more("还有 \(pinned.count - Self.pinLimit) 处改动或出错") }
                        .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
            .transition(.opacity)
        }
    }

    private func more(_ text: String) -> some View {
        Text(text).font(Typography.caption).foregroundStyle(palette.ink3).padding(.leading, 19).contentShape(.rect)
    }

    private func row(_ item: PiChatMessage.Tools.Item) -> some View {
        ToolRow(symbol: Self.symbol(item.kind), target: Text(item.target), truncation: item.kind == .command ? .tail : .middle) { status(item) }
    }

    @ViewBuilder private func status(_ item: PiChatMessage.Tools.Item) -> some View {
        if item.failed {
            Text("失败").font(Typography.caption).foregroundStyle(palette.failure)
        } else if item.added != nil || item.removed != nil {
            Text(PiChat.diffLabel(added: item.added, removed: item.removed)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
        }
    }

    /// 正在跑的那一步：与清单同一种行，文字是会话状态里的当前动作、带流光，放得下两行。
    private func liveStep(_ doing: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(Typography.caption2).foregroundStyle(palette.ink3)
                .frame(width: 13).accessibilityHidden(true)
            Text(doing).font(Typography.codeNote).lineLimit(2).truncationMode(.middle).shimmering()
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    /// 正在跑的那一步的图标，按会话状态里的工具名（`PiSessionState.detail` 的前一截）：与清单里同一类同一个图标；还没调工具（在想）是省略号。
    static func symbol(tool: String?) -> String {
        switch tool?.lowercased() {
        case nil: "ellipsis"
        case "edit", "write": symbol(.edit)
        case "bash": symbol(.command)
        case "read": symbol(.read)
        case "grep", "find", "glob", "ls": symbol(.search)
        default: symbol(.other)
        }
    }

    static func symbol(_ kind: PiChatMessage.Tools.Kind) -> String {
        switch kind {
        case .edit: "pencil"
        case .command: "terminal"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .other: "wrench.and.screwdriver"
        }
    }
}

extension View {
    /// 一轮经过那一块的外形（`RoundProcess`）：与代码块、表格同一套淡底与圆角。
    func roundNoteFrame() -> some View { modifier(RoundNoteFrame()) }

    /// 那一块里的一行：小字、次要墨色、固定的最小行高。
    func roundNoteLine() -> some View { modifier(RoundNoteLine()) }
}

private struct RoundNoteFrame: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(.horizontal, ChatBlock.inset / 1.5).padding(.vertical, 4).background(palette.fill, in: ChatBlock.shape)
    }
}

private struct RoundNoteLine: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink2).frame(minHeight: 24)
    }
}

/// 就地展开的那一行末尾的箭头（工具清单、子代理汇总、Cue 的运行情况共用）：收着朝下，展开转过来朝上。
struct DisclosureChevron: View {
    let open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "chevron.down").font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            .rotationEffect(.degrees(open ? 180 : 0))
            .accessibilityHidden(true)
    }
}

/// 工具清单的一行（会话里回答注脚的清单、Cue 的运行情况共用）：图标、等宽小字的目标、右侧状态。
struct ToolRow<Status: View>: View {
    let symbol: String
    let target: Text
    let truncation: Text.TruncationMode
    @ViewBuilder let status: Status
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(Typography.caption2).foregroundStyle(palette.ink3)
                .frame(width: 13).accessibilityHidden(true)
            target.font(Typography.codeNote).foregroundStyle(palette.ink3)
                .lineLimit(1).truncationMode(truncation)
            Spacer(minLength: 4)
            status
        }
        .accessibilityElement(children: .combine)
    }
}
