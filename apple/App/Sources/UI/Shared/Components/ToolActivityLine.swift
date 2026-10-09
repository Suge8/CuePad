import CueStore
import SwiftUI

/// 一轮回答上方的一行经过："改了 2 个文件，运行了 5 条命令 · 2 分"，点开就地展开这一轮的工具清单，再点收起。
/// 与代码块、表格同一套底色与圆角（`ChatBlock`），收成贴着字的一小块。没调工具时只是一行"用时 8 秒"，不可点。
/// 清单每条一行：图标、文件路径或命令、状态——改文件写 +行数 −行数，失败的写"失败"（胭脂）；不显示工具输出。
struct ToolActivityLine: View {
    let meta: String
    let tools: PiChatMessage.Tools?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    // 截图验收：-CuePadToolsOpen YES 让每一轮的工具清单一开始就展开
    @State private var expanded = DebugScene.defaults.bool(forKey: "CuePadToolsOpen")
    #else
    @State private var expanded = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tools {
                Button { expanded.toggle() } label: { header(chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                if expanded { list(tools) }
            } else {
                header(chevron: false)
            }
        }
        .padding(.horizontal, ChatBlock.inset / 1.5).padding(.vertical, 4)
        .background(palette.fill, in: ChatBlock.shape)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
    }

    private func header(chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "wrench.and.screwdriver").imageScale(.small).accessibilityHidden(true)
            Text(meta)
            if chevron {
                Image(systemName: "chevron.down").font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink2)
        .frame(minHeight: 24)
        .contentShape(.rect)
    }

    private func list(_ tools: PiChatMessage.Tools) -> some View {
        let hidden = tools.total - tools.items.count
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(tools.items.enumerated()), id: \.offset) { _, item in row(item) }
            if hidden > 0 { Text("另有 \(hidden) 项未列出").font(Typography.caption).foregroundStyle(palette.ink3).padding(.leading, 21) }
        }
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private func row(_ item: PiChatMessage.Tools.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.failed ? "xmark.circle.fill" : Self.symbol(item.kind))
                .font(Typography.caption).foregroundStyle(item.failed ? palette.failure : palette.ink3)
                .frame(width: 13).accessibilityHidden(true)
            Text(item.target).font(Typography.code).foregroundStyle(palette.ink2)
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
