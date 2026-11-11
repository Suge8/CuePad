import CueStore
import SwiftUI

/// "重点"（钉住的）只有 Cue 整理，它并成的就是普通的一条，不另标。一条只剩正文：时间在组头，谁说的与确切日期只在长按（右键）菜单的抬头与读屏里——一屏要看得到十来条。
/// 忘掉先确认：库里忘掉是软删、界面上没有拨回去的路。
struct CueMemoryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var memory: CueMemoryRecent?
    @State private var text = ""
    @State private var forgetting: CueMemoryLine?
    @FocusState private var adding: Bool

    /// 有字但记不成一条（`CueMemoryLine.fits`：写入时同一个判断）。
    private var tooLong: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !CueMemoryLine.fits(text) }

    var body: some View {
        let kept = memory?.lines ?? [], pinned = kept.filter(\.pinned), others = kept.filter { !$0.pinned }
        let name = workspace.cue.name
        CueListPanel(
            title: String(localized: "\(name) 记得什么"),
            help: String(localized: "\(name) 自己记下的事和你说过的话。重点每次都会看，其余的越早越概括，用到时再翻。"),
            isEmpty: memory != nil && kept.isEmpty
        ) {
            if !pinned.isEmpty {
                GroupTitle(title: String(localized: "重点"), icon: .pin) { PinnedUsage(bytes: CueMemoryLine.bytes(pinned)) }
                ForEach(pinned) { row($0).transition(.opacity) }
            }
            ForEach(TimeSection.split(others, date: \.createdAt, now: .now), id: \.section) { run in
                GroupTitle(title: run.section.title)
                ForEach(run.items) { row($0).transition(.opacity) }
            }
        } field: {
            field
        } empty: {
            EmptyState(mascot: .empty, title: "还没记住什么", message: "你说过的要紧事，它会自己记下")
        }
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: kept)
        .observing(services.store, into: $memory, onError: workspace.fail) { try $0.recentCueMemory() }
        .dialog("忘掉这一条？", item: $forgetting, message: "\(name) 之后不再记得它，找不回来") { line in
            [DialogButton(title: "忘掉", role: .destructive) { workspace.forgetCueLine(line.id) }]
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.item) {
                Image(.add).font(Glyph.row).foregroundStyle(palette.ink2).readerHidden(true)
                TextField(String(localized: "记一条"), text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("记一条")
            }
            .frame(minHeight: CueListMetrics.field)
            if tooLong {
                Text("一条最多 \(CueMemoryLine.maxBytes) 字节，拆成几条记").font(Typography.meta).foregroundStyle(palette.failure)
                    .padding(.bottom, Spacing.group)
            }
        }
    }

    private func row(_ line: CueMemoryLine) -> some View {
        let id = line.id, pinned = line.pinned
        return CueListRow(
            label: line.text, meta: Dotted(DateLabel.short(line.createdAt), line.source == .known(.you) ? String(localized: "你说的") : nil),
            copy: .copy(line.text, workspace),
            leading: RowAction(pinned ? "取消重点" : "标为重点", icon: pinned ? .unpin : .pin) { workspace.pinCueLine(id, !pinned) },
            trailing: RowAction("忘掉", icon: .remove, tone: .destructive) { forgetting = line }
        ) {
            Text(line.text).foregroundStyle(palette.ink)
                .font(Typography.body)
                #if os(macOS)
                .lineSpacing(Typography.lineSpacing)
                #endif
        }
    }

    private func add() {
        guard CueMemoryLine.fits(text) else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.attempt {
            try await workspace.noteCueLine(line)
            text = ""
            adding = true
        }
    }
}

extension RowAction {
    static func copy(_ text: String, _ workspace: Workspace) -> RowAction {
        RowAction(.verbatim(MessageMenu.Item.copy.title), icon: MessageMenu.Item.copy.icon) { workspace.copy(text) }
    }
}

private struct GroupTitle<Trailing: View>: View {
    let title: String
    var icon: Icon?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.group) {
            SectionHeader(Dotted(title), level: .group, icon: icon)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, CueListMetrics.inset).padding(.top, Spacing.part).padding(.bottom, Spacing.hair)
    }
}

extension GroupTitle where Trailing == EmptyView {
    init(title: String, icon: Icon? = nil) { self.init(title: title, icon: icon) { EmptyView() } }
}

private struct PinnedUsage: View {
    let bytes: Int
    @Environment(\.palette) private var palette

    private static let width: CGFloat = 56

    var body: some View {
        let fraction = min(Double(bytes) / Double(CueMemoryLine.pinnedHard), 1)
        let level = UsageLevel(used: fraction)
        let used = Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes).converted(to: .kilobytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        HStack(spacing: Spacing.item) {
            MarkedBar(fill: fraction, mark: nil, level: level).frame(width: Self.width)
            Text(verbatim: used).monospacedDigit().foregroundStyle(level == .critical ? palette.failure : palette.ink3)
                .contentTransition(.numericText(value: fraction))
        }
        .font(Typography.meta)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: used))
        .animation(Motion.fade, value: bytes)
    }
}
