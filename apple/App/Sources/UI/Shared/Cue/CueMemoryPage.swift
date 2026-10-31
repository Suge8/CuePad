import CueStore
import SwiftUI

/// "Cue 记得什么"（Cue 页上打开的弹层，入口见 `CuePage`；手机与 Mac 同一张列表，壳是 `CueListPanel`）：没忘掉、不是定时的记忆，
/// 最上面是"一直记着"（钉住的）一组、组头右端是它的用量（`PinnedUsage`；后台整理合并过的就是普通的一条，不另标），其余按记下的时间分段（今天、昨天、本周、本月、更早，同会话历史 `TimeSection`），组内从新到旧。
/// 一条只剩正文：时间在组头，谁说的与确切日期只在长按（右键）菜单的抬头与读屏里——一屏要看得到十来条。定时另有一张（`CueSchedulePage`）。
/// 记一条是浮在底部的玻璃胶囊；记下的算你说的，一条超过 `CueMemoryLine.maxBytes` 字节时在胶囊里说明、不写。
/// 钉住与忘掉按平台惯例收起（`CueListRow`）；忘掉先确认：库里忘掉是软删、界面上没有拨回去的路。
struct CueMemoryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 记忆（没忘掉、不是定时的），新的在前
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
            help: String(localized: "\(name) 自己记下的事和你说过的话。一直记着的每次都会看，其余的越早越概括，用到时再翻。"),
            isEmpty: memory != nil && kept.isEmpty
        ) {
            if !pinned.isEmpty {
                GroupTitle(title: String(localized: "一直记着"), icon: .pin) { PinnedUsage(bytes: CueMemoryLine.bytes(pinned)) }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(.add).font(Glyph.row).foregroundStyle(palette.ink2).accessibilityHidden(true)
                TextField(String(localized: "记一条"), text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("记一条")
            }
            .frame(minHeight: CueListMetrics.field)
            if tooLong {
                Text("一条最多 \(CueMemoryLine.maxBytes) 字节，拆成几条记").font(Typography.meta).foregroundStyle(palette.failure)
                    .padding(.bottom, 12)
            }
        }
    }

    private func row(_ line: CueMemoryLine) -> some View {
        let id = line.id, pinned = line.pinned
        return CueListRow(
            label: line.text, meta: Dotted(DateLabel.short(line.createdAt), line.source == .known(.you) ? String(localized: "你说的") : nil),
            copy: .copy(line.text, workspace),
            leading: RowAction(pinned ? "不再一直记着" : "一直记着", icon: pinned ? .unpin : .pin) { workspace.pinCueLine(id, !pinned) },
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
    /// 复制这一行的字（菜单与读屏里）。
    static func copy(_ text: String, _ workspace: Workspace) -> RowAction {
        RowAction(.verbatim(MessageMenu.Item.copy.title), icon: MessageMenu.Item.copy.icon) { workspace.copy(text) }
    }
}

/// 组头：小号、第三档墨，可带一枚图标，右端可挂一样东西（一直记着的用量）；上面空出一段把组分开。
private struct GroupTitle<Trailing: View>: View {
    let title: String
    var icon: Icon?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SectionLabel(text: Dotted(title), icon: icon)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, CueListMetrics.inset).padding(.top, 20).padding(.bottom, 2)
    }
}

extension GroupTitle where Trailing == EmptyView {
    init(title: String, icon: Icon? = nil) { self.init(title: title, icon: icon) { EmptyView() } }
}

/// 一直记着的用量：一条用量条（`MarkedBar`，不带刻线）铺到硬线（`CueMemoryLine.pinnedHard`）的比例，旁边是已用多少（kB，一位小数）。
/// 不画软线：过了它后台马上合并收口，那一段一闪而过，刻线只会让人猜它是什么。用量档位与配色同上下文那一行（`UsageLevel`），平时是安静的次要墨。
private struct PinnedUsage: View {
    let bytes: Int
    @Environment(\.palette) private var palette

    private static let width: CGFloat = 56

    var body: some View {
        let fraction = min(Double(bytes) / Double(CueMemoryLine.pinnedHard), 1)
        let level = UsageLevel(used: fraction)
        let used = Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes).converted(to: .kilobytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        HStack(spacing: 8) {
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
