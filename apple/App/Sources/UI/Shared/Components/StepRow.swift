import CueStore
import SwiftUI
#if os(macOS)
import CueBridge
#endif

/// 清单里的一步。会话在这台 Mac 上、它的会话文件里认得出这次调用时（`AppServices.readsSteps`），点开在原位看里面：
/// 命令全文或改动的前后，下面是输出的末尾（`ToolCallDetail`，点开才回会话文件取）。别的设备上只是一行。
struct StepRow: View {
    let item: ChatMessage.Tools.Item
    let session: SessionState
    @Environment(\.palette) private var palette
    #if os(macOS)
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened: Opened?

    enum Opened: Equatable { case loading, ready(ToolCallDetail), missing }
    #endif

    var body: some View {
        #if os(macOS)
        if let calls = item.calls, services.readsSteps(of: session) {
            VStack(alignment: .leading, spacing: 0) {
                Button { toggle(calls) } label: { row(open: opened != nil) }
                    .buttonStyle(PressStyle())
                    .accessibilityExpanded(opened != nil)
                // 读是毫秒级的：读的那一下不另画"正在读"，读到了直接展开
                switch opened {
                case .ready(let detail): StepWell(detail: detail)
                case .missing: Text("会话文件里找不到这一步了").font(Typography.caption).foregroundStyle(palette.ink3).noteGlyph(.indent).transition(.opacity)
                case .loading, nil: EmptyView()
                }
            }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: opened)
        } else {
            row(open: nil)
        }
        #else
        row(open: nil)
        #endif
    }

    private func row(open: Bool?) -> some View {
        ToolRow(icon: RoundProcess.icon(item.kind), target: Text(item.target), truncation: item.kind == .command ? .tail : .middle) {
            if item.failed {
                Text("失败").font(Typography.caption).foregroundStyle(palette.failure)
            } else if item.added != nil || item.removed != nil {
                Text(Chat.diffLabel(added: item.added, removed: item.removed)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            if let open { DisclosureChevron(open: open) }
        }
        .contentShape(.rect)
    }

    #if os(macOS)
    private func toggle(_ calls: [String]) {
        guard opened == nil else { return opened = nil }
        opened = .loading
        Task {
            let detail = await services.stepDetail(calls, in: session)
            if opened == .loading { opened = detail.map(Opened.ready) ?? .missing }
        }
    }
    #endif
}

#if os(macOS)
private struct StepWell: View {
    let detail: ToolCallDetail
    @Environment(\.palette) private var palette

    /// 输出只排最后这么多行：结论在末尾，更长的在对话里再套一层滚动不好读。
    private static let lines = 40

    var body: some View {
        let output = detail.output.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let command = detail.command {
                Text(command).foregroundStyle(palette.ink).selectable()
            }
            ForEach(Array(detail.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 0) {
                    side(change.removed, sign: "−", fill: palette.diffRemoved)
                    side(change.added, sign: "+", fill: palette.diffAdded)
                }
                .clipShape(.rect(cornerRadius: Radius.chip))
            }
            if !output.isEmpty {
                if detail.command != nil || !detail.changes.isEmpty { palette.hair.frame(height: 1) }
                if detail.clipped || output.count > Self.lines {
                    Text("更早的输出未显示").font(Typography.caption).foregroundStyle(palette.ink3)
                }
                Text(output.suffix(Self.lines).joined(separator: "\n")).foregroundStyle(palette.ink2).selectable()
            }
        }
        .font(Typography.codeNote)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill, in: .rect(cornerRadius: Radius.block))
        .padding(.vertical, Spacing.tight)
        .noteGlyph(.indent)
        .transition(.opacity)
    }

    @ViewBuilder private func side(_ text: String, sign: String, fill: Color) -> some View {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if !text.isEmpty {
            Text((all.prefix(Self.lines).map { "\(sign) \($0)" } + (all.count > Self.lines ? ["…"] : [])).joined(separator: "\n")).foregroundStyle(palette.ink).selectable()
                .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill)
        }
    }
}
#endif
