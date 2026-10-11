import CueStore
import SwiftUI

/// 一轮回答上方的注脚："改了 2 个文件，运行了 5 条命令 · 2 分钟"，固定一行：放不下时摘要按优先级少写几类
/// （`PiChat.toolSummaries` 从全到简）。失败的调用与别的一样算进各类，注脚里不单独写、不标色。点开就地展开这一轮的工具清单，再点收起。
/// 与代码块、表格同一套底色与圆角（`ChatBlock`），收成贴着字的一小块。没调工具时只是一行"用时 8 秒"，不可点。
/// 清单是回答的注脚：小一档的等宽字、次要墨色、行距收紧；每条一行，图标、文件路径或命令、状态——改文件写 +行数 −行数，
/// 失败的只把"失败"两个字标胭脂；不显示工具输出。
struct ToolActivityLine: View {
    let note: PiChat.RoundNote
    let tools: PiChatMessage.Tools?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.toolsOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tools {
                Button { expanded.toggle() } label: { header(chevron: true) }
                    .buttonStyle(.plain)
                    // 读屏只读这一句：图标是装饰
                    .accessibilityLabel(spoken)
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                if expanded { list(tools) }
            } else {
                header(chevron: false).accessibilityElement(children: .ignore).accessibilityLabel(spoken)
            }
        }
        .padding(.horizontal, ChatBlock.inset / 1.5).padding(.vertical, 4)
        .background(palette.fill, in: ChatBlock.shape)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
    }

    /// 读屏读的一句：最全的摘要与用时。
    private var spoken: String {
        [note.summaries.first, note.summaries.isEmpty ? "用时 \(note.took)" : note.took].compactMap { $0 }.joined(separator: "，")
    }

    /// 取第一种整行放得下的写法；最简的也放不下时截断摘要，用时不截。
    private func header(chevron: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(note.summaries, id: \.self) { line($0, chevron: chevron).fixedSize() }
            line(note.summaries.last, chevron: chevron)
        }
        .font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink2)
        .frame(minHeight: 24)
        .contentShape(.rect)
    }

    private func line(_ summary: String?, chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "wrench.and.screwdriver").imageScale(.small).accessibilityHidden(true)
            if let summary {
                Text(summary).lineLimit(1).layoutPriority(-1)
                Dot()
                Text(note.took).fixedSize()
            } else {
                Text("用时 \(note.took)").fixedSize()
            }
            if chevron {
                Image(systemName: "chevron.down").font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
    }

    private func list(_ tools: PiChatMessage.Tools) -> some View {
        let hidden = tools.total - tools.items.count
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(tools.items.enumerated()), id: \.offset) { _, item in row(item) }
            if hidden > 0 { Text("另有 \(hidden) 项未列出").font(Typography.caption).foregroundStyle(palette.ink3).padding(.leading, 19) }
        }
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private func row(_ item: PiChatMessage.Tools.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(item.kind))
                .font(Typography.caption2).foregroundStyle(palette.ink3)
                .frame(width: 13).accessibilityHidden(true)
            Text(item.target).font(Typography.codeNote).foregroundStyle(palette.ink3)
                .lineLimit(1).truncationMode(item.kind == .command ? .tail : .middle)
            Spacer(minLength: 4)
            status(item)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func status(_ item: PiChatMessage.Tools.Item) -> some View {
        if item.failed {
            Text("失败").font(Typography.caption).foregroundStyle(palette.failure)
        } else if item.added != nil || item.removed != nil {
            Text(PiChat.diffLabel(added: item.added, removed: item.removed)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
        }
    }

    private static func symbol(_ kind: PiChatMessage.Tools.Kind) -> String {
        switch kind {
        case .edit: "pencil"
        case .command: "terminal"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .other: "wrench.and.screwdriver"
        }
    }
}
