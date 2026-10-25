import CueStore
import SwiftUI

/// 输入框里的按键（面板打开时由输入框的文字区交给面板处理）。
enum ComposerKey { case up, down, accept, dismiss }

/// 输入 "/" 弹出的斜杠命令面板（回复框与发给 Agent 的输入框共用，嵌在输入框的玻璃里）：每行一条命令——名字、参数提示、一行说明，
/// 右侧标明来源（内置、扩展、模板、技能）；方向键移动高亮、↩ 或 Tab 选中、Esc 收起，点按直接选。选中只把 "/名字 " 放进输入框，接着写参数，发送照常。
struct PiSlashPalette: View {
    let commands: [PiSlashCommand]
    let highlighted: Int
    let pick: (PiSlashCommand) -> Void
    @Environment(\.palette) private var palette

    private static let maxHeight: CGFloat = 264

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command, highlighted: index == highlighted).id(command.id)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                if commands.indices.contains(index) { proxy.scrollTo(commands[index].id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("斜杠命令")
    }

    private func row(_ command: PiSlashCommand, highlighted: Bool) -> some View {
        Button { pick(command) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("/" + command.name).font(Typography.body.weight(.semibold)).foregroundStyle(palette.ink)
                        if let hint = command.hint { Text(hint).font(Typography.meta).foregroundStyle(palette.ink3) }
                    }
                    .lineLimit(1)
                    if let summary = command.summary {
                        Text(summary).font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(command.source.label).font(Typography.caption).foregroundStyle(palette.ink3)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: highlighted))
        .accessibilityLabel("/" + command.name)
        .accessibilityValue([command.hint, command.summary, command.source.label].compactMap { $0 }.joined(separator: "，"))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

nonisolated extension Open<PiCommandSource> {
    var label: String {
        switch self {
        case .known(.builtin): String(localized: "内置")
        case .known(.extension): String(localized: "扩展")
        case .known(.prompt): String(localized: "模板")
        case .known(.skill): String(localized: "技能")
        case .unknown: String(localized: "其他")
        }
    }
}
