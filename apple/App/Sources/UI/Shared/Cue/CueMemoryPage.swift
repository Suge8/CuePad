import CueStore
import SwiftUI

/// "Cue 记得什么"（Cue 页上打开的弹层，入口见 `CuePage`；手机与 Mac 同一张列表）：没忘掉的记忆，最上面是"定时"一组（先到点的在前，每条下面一行
/// 怎么重复与下一次、错过后补上的那句事实；点一条原地展开改，`ScheduleEditor`），再是"一直记着"（钉住的）一组，其余按记下的时间分段
/// （今天、昨天、本周、本月、更早，同会话历史 `TimeSection`），组内从新到旧。顶上不写标题，一条只剩正文：时间在组头，
/// 来源（"你记的"）与确切日期只在长按（右键）菜单的抬头与读屏里——一屏要看得到十来条。
/// 记一条是浮在底部的玻璃胶囊，列表从它后面透过；记下的算你记的，一条超过 `CueMemoryLine.maxBytes` 字节时在胶囊里说明、不写。
/// 胶囊右边"到点"在它上面展开一块定时，记下的就是一条定时（到点由 Mac 上的 Cue 照它做）。
/// 钉住与忘掉（定时是改与不再定时，另有复制）按平台惯例收起：手机右滑钉住、左滑忘掉、长按出菜单；Mac 右键出菜单，指针停在一行时铺行的淡底（`RowStyle`）、右下角露出两颗小钮。
/// 忘掉、不再定时先确认：库里忘掉是软删、界面上没有拨回去的路。
struct CueMemoryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: MemoryShown?
    @State private var text = ""
    @State private var forgetting: CueMemoryLine?
    @State private var ending: CueMemoryLine?
    /// 原地展开在改的那条定时
    @State private var rescheduling: Rescheduling?
    /// 点了"到点"：记下的这一条带着它成为定时
    @State private var schedule: ScheduleDraft? = DebugHooks.preset.scheduleOpen ? ScheduleDraft() : nil
    @FocusState private var adding: Bool

    private var title: String { String(localized: "\(workspace.cue.name) 记得什么") }
    /// 定时之外没忘掉的记忆，新的在前（定时在最上面一组）
    private var kept: [CueMemoryLine] { (shown?.memory.lines ?? []).filter { $0.deletedAt == nil && $0.remindAt == nil }.reversed() }
    /// 有字但记不成一条（`CueMemoryLine.fits`：写入时同一个判断）。
    private var tooLong: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !CueMemoryLine.fits(text) }

    var body: some View {
        content
            .observing(services.store, into: $shown, onError: workspace.fail) { MemoryShown(memory: try $0.cueMemory(), schedules: try $0.cueSchedules()) }
            .dialog("忘掉这一条？", item: $forgetting, message: "\(workspace.cue.name) 之后不再记得它，找不回来") { line in
                [DialogButton(title: "忘掉", role: .destructive) { workspace.forgetCueLine(line.id) }]
            }
            .stopScheduleDialog($ending)
    }

    private var list: some View {
        let kept = kept, pinned = kept.filter(\.pinned), others = kept.filter { !$0.pinned }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let schedules = shown?.schedules, !schedules.isEmpty {
                    groupTitle(String(localized: "定时"), icon: .schedule)
                    ForEach(schedules) { scheduled($0).transition(.opacity) }
                }
                if !pinned.isEmpty {
                    groupTitle(String(localized: "一直记着"), icon: .pin)
                    ForEach(pinned) { row($0).transition(.opacity) }
                }
                ForEach(TimeSection.split(others, date: \.createdAt, now: .now), id: \.section) { run in
                    groupTitle(run.section.title)
                    ForEach(run.items) { row($0).transition(.opacity) }
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.bottom, 12)
        }
        .scrollEdgeEffectHidden()
        .overlay {
            if let shown, kept.isEmpty, shown.schedules.isEmpty {
                EmptyState(mascot: .empty, title: "还没记住什么", message: "你说过的要紧事，它会自己记下").padding(20)
            }
        }
        // 滚动区止于胶囊半高处，胶囊下半截伸出滚动区：内容只从胶囊背后滚过，不在它下面与圆角外露出被面板下沿切掉的半行
        .safeAreaInset(edge: .bottom, spacing: 0) { field.padding(.bottom, -Metrics.field / 2) }
        .padding(.bottom, Metrics.fieldBottom + Metrics.field / 2)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: kept)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: shown?.schedules)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: rescheduling?.id)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let draft = schedule {
                ScheduleEditor(
                    text: "", draft: Binding { schedule ?? draft } set: { schedule = $0 }, savable: CueMemoryLine.fits(text), save: add, cancel: { schedule = nil })
                    .padding(.top, 12)
            }
            HStack(spacing: 10) {
                Image(.add).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                TextField(String(localized: "记一条"), text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("记一条")
                Button { schedule = schedule == nil ? ScheduleDraft() : nil } label: {
                    Label("到点", icon: .schedule).font(Typography.meta.weight(.medium))
                        .foregroundStyle(schedule == nil ? palette.ink2 : palette.signature)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(schedule == nil ? palette.fill : palette.selection, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .accessibilityHint("记下的这一条到点叫醒 \(workspace.cue.name)")
            }
            .frame(minHeight: Metrics.field)
            if tooLong {
                Text("一条最多 \(CueMemoryLine.maxBytes) 字节，拆成几条记").font(Typography.meta).foregroundStyle(palette.failure)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 18)
        .glass(in: .rect(cornerRadius: Metrics.field / 2, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func groupTitle(_ title: String, icon: Icon? = nil) -> some View {
        SectionLabel(text: Dotted(title), icon: icon).padding(.horizontal, Metrics.inset).padding(.top, 20).padding(.bottom, 2)
    }

    private func row(_ line: CueMemoryLine) -> MemoryRow {
        let id = line.id, pinned = line.pinned
        return MemoryRow(
            line: line, copy: copy(line),
            leading: RowAction(pinned ? "不再一直记着" : "一直记着", icon: pinned ? .unpin : .pin) { workspace.pinCueLine(id, !pinned) },
            trailing: RowAction("忘掉", icon: .remove, tone: .destructive) { forgetting = line })
    }

    /// 一条定时：下面一行怎么重复、下一次（错过后补上的写那句事实）；改的时候原地换成 `ScheduleEditor`。
    @ViewBuilder private func scheduled(_ item: CueScheduled) -> some View {
        let line = item.line, id = line.id
        if let editing = rescheduling, editing.id == id {
            ScheduleEditor(
                text: line.text, draft: Binding { rescheduling?.draft ?? editing.draft } set: { rescheduling?.draft = $0 },
                save: {
                    workspace.rescheduleCueLine(id, rescheduling?.draft ?? editing.draft)
                    rescheduling = nil
                },
                cancel: { rescheduling = nil }, end: { ending = line }
            )
            .padding(.vertical, 6)
        } else {
            let next = line.remindAt.map { String(localized: "下一次 \(ScheduleText.moment($0))") }
            let late = item.last.flatMap { $0.late ? ScheduleText.missed($0) : nil }
            MemoryRow(
                line: line, note: Dotted(ScheduleText.repeats(line.repeats), late ?? next), copy: copy(line),
                leading: RowAction("改", icon: .write) { rescheduling = Rescheduling(id: id, draft: ScheduleDraft(line)) },
                trailing: RowAction("不再定时", icon: .remove, tone: .destructive) { ending = line })
        }
    }

    private func copy(_ line: CueMemoryLine) -> RowAction {
        let text = line.text
        return RowAction(.verbatim(MessageMenu.Item.copy.title), icon: MessageMenu.Item.copy.icon) { workspace.copy(text) }
    }

    private func add() {
        guard CueMemoryLine.fits(text), schedule?.valid() != false else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = schedule
        workspace.attempt {
            try await workspace.noteCueLine(line, schedule: draft)
            text = ""
            schedule = nil
            adding = true
        }
    }

    #if os(macOS)
    private var content: some View {
        list
            .safeAreaPadding(.top, 14)
            .contentMargins(.top, -14, for: .scrollIndicators)
            .overlay(alignment: .topTrailing) { PanelCloseButton().padding(12) }
            .frame(width: 480).frame(maxHeight: 600)
            .background(palette.desk)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }
    #else
    private var content: some View {
        NavigationStack {
            list
                .background(palette.desk)
                .navigationTitle(title)
                // 标题只给读屏与多任务，顶上不写：移除标题项只去掉小标题，大标题还要靠 inline 才不出现
                .toolbar(removing: .title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { close() } }
                }
        }
        .presentationDetents([.large])
    }
    #endif
}

/// 这一页一次读出的：记忆与定时（同一次读，一条一次性定时到点后从"定时"挪进其他记忆时不在两帧里各变一半）。
nonisolated private struct MemoryShown: Equatable, Sendable {
    var memory: CueMemory
    var schedules: [CueScheduled]
}

/// 原地展开在改的那条定时与手上的那一份。
private struct Rescheduling: Equatable {
    let id: UUID
    var draft: ScheduleDraft
}

/// 一组记忆的组头：小号、第三档墨，"一直记着"带一枚钉；上面空出一段把组分开。
/// 记忆的一行：正文占满宽度，定时下面多一行（`note`）。两个动作（钉住与忘掉，定时是改与不再定时）手机上在右滑、左滑；
/// 菜单与读屏另有复制，菜单抬头与读屏另说什么时候、是不是你记的。
private struct MemoryRow: View {
    let line: CueMemoryLine
    var note: Dotted?
    let copy: RowAction
    /// 手机上右滑的那个
    let leading: RowAction
    /// 删的那个：手机上左滑
    let trailing: RowAction
    @Environment(\.palette) private var palette

    private var meta: Dotted { Dotted(DateLabel.short(line.createdAt), line.source == .known(.you) ? String(localized: "你记的") : nil) }
    private var actions: [RowAction] { [leading, trailing] }
    private var menu: some View {
        Section(meta.visible) { RowActionButtons(actions: [copy] + actions) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.text).foregroundStyle(palette.ink)
                .font(Typography.body)
                #if os(macOS)
                .lineSpacing(Typography.lineSpacing)
                #endif
            if let note { Text(note).font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1) }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.vertical)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(line.text)
            .accessibilityValue(((note ?? Dotted()) + meta).spoken)
            #if os(iOS)
            // 长按抬起的预览与左右滑时露出的缝是这一行的快照：没有底色时抬起来是透明的一条。形状要写明：不写时 iOS 26 按所在容器取同心圆角
            .background(palette.desk, in: .rect)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Metrics.radius, style: .continuous))
            .contextMenu { menu }
            .rowSwipes(RowSwipes(leading: [leading], trailing: [trailing]))
            #else
            .hoverReveal(.bottomTrailing) { MemoryHoverActions(actions: actions) }
            .row()
            .contextMenu { menu }
            .accessibilityActions { RowActionButtons(actions: [copy] + actions) }
            #endif
    }
}

#if os(macOS)
/// 指针停在行上时右下角浮出的两个动作（`hoverReveal`）：钉住与忘掉，定时是改与不再定时。
private struct MemoryHoverActions: View {
    let actions: [RowAction]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions.keyed, id: \.key) { item in
                Button(item.action.title, icon: item.action.icon, action: item.action.run)
                    .labelStyle(.iconOnly)
                    .font(Typography.meta.weight(.medium))
                    .foregroundStyle(item.action.tone == .destructive ? palette.failure : palette.ink2)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
                    .help(item.action.title)
            }
        }
        .padding(.leading, 4)
    }
}
#endif

/// 页边距（Mac 的行底向两边伸出 `RowMetrics.bleed`，边距要盖住它）、行的内边距、手机长按预览的圆角、记一条的高与离底：Mac 是 480 宽的浮层，手机是整屏 sheet。
private enum Metrics {
    #if os(macOS)
    static let margin: CGFloat = 20
    static let inset: CGFloat = 0
    static let vertical: CGFloat = 7
    static let field: CGFloat = 44
    static let fieldBottom: CGFloat = 16
    #else
    static let margin: CGFloat = 4
    static let inset: CGFloat = 16
    static let vertical: CGFloat = 9
    static let radius: CGFloat = 16
    static let field: CGFloat = 50
    static let fieldBottom: CGFloat = 8
    #endif
}
