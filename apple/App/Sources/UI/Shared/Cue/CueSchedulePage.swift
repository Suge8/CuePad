import CueStore
import SwiftUI

/// 定时（入口见 `CuePage`；手机与 Mac 同一张列表，壳是 `CueListPanel`）：Cue 到点照着做的那几句，先到点的在前。
/// 一行左边是几点，右边是那句话，下面一行是哪天（重复的写"每天""每周一和周四"，一次的写"明天"）、挂在哪件任务上、错过后补上的那句事实；
/// 点"改"原地展开成 `ScheduleEditor`。新定时是浮在底部的玻璃胶囊：写要做的事，右边那颗写着几点，点开在胶囊上方选。
/// 改与不再定时按平台惯例收起（`CueListRow`）；不再定时先确认：库里是软删、界面上没有拨回去的路。
struct CueSchedulePage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: ScheduleShown?
    @State private var text = ""
    @State private var draft = ScheduleDraft()
    /// 新定时的几点展开在选
    @State private var picking = DebugHooks.preset.scheduleOpen
    @State private var ending: CueMemoryLine?
    /// 原地展开在改的那条
    @State private var rescheduling: Rescheduling?
    @FocusState private var adding: Bool

    var body: some View {
        let name = workspace.cue.name, host = workspace.cue.hostName ?? MacAgents.unnamed
        let schedules = shown?.schedules ?? []
        CueListPanel(
            title: String(localized: "定时"),
            help: String(localized: "到点时，\(name) 在「\(host)」上照这句话去做；挂在任务上的，到点开工那件任务。也可以直接跟 \(name) 说，比如「每天早上 8 点汇总进展」。"),
            isEmpty: shown != nil && schedules.isEmpty
        ) {
            Color.clear.frame(height: 8)
            ForEach(schedules) { row($0).transition(.opacity) }
        } field: {
            field
        } empty: {
            EmptyState(mascot: .empty, title: "还没有定时", message: "跟 \(name) 说「每天早上 8 点汇总进展」，它就会到点去做")
        }
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: schedules)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: rescheduling?.id)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: picking)
        .observing(services.store, into: $shown, onError: workspace.fail) { try ScheduleShown.read($0) }
        .stopScheduleDialog($ending)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            if picking {
                ScheduleEditor(text: "", draft: $draft, savable: CueMemoryLine.fits(text), save: add, cancel: { picking = false })
                    .padding(.top, 12)
            }
            HStack(spacing: 10) {
                Image(.add).font(Glyph.row).foregroundStyle(palette.ink2).accessibilityHidden(true)
                TextField(String(localized: "到时候做什么"), text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("新定时")
                Button { picking.toggle() } label: {
                    let when = ScheduleText.when(draft)
                    Label { Text(verbatim: "\(when.day) \(when.time)") } icon: { Image(.schedule) }
                        .font(Typography.meta.weight(.medium)).monospacedDigit()
                        .foregroundStyle(picking ? palette.signature : palette.ink2)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(picking ? palette.selection : palette.fill, in: .capsule).contentShape(.capsule)
                        .fixedSize()
                }
                .buttonStyle(PressStyle())
                .accessibilityHint("选几点")
            }
            .frame(minHeight: CueListMetrics.field)
        }
    }

    @ViewBuilder private func row(_ item: CueScheduled) -> some View {
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
            let day = ScheduleText.days(line)
            let task = line.task.flatMap { shown?.tasks[$0] }.map { String(localized: "开工「\($0)」") }
            let late = item.last.flatMap { $0.late ? ScheduleText.missed($0) : nil }
            let note = Dotted(day, task, late)
            CueListRow(
                label: line.text, meta: Dotted(ScheduleText.time(line), note.visible),
                copy: .copy(line.text, workspace),
                leading: RowAction("改", icon: .write) { rescheduling = Rescheduling(id: id, draft: ScheduleDraft(line)) },
                trailing: RowAction("不再定时", icon: .remove, tone: .destructive) { ending = line }
            ) {
                HStack(alignment: .firstTextBaseline, spacing: ScheduleMetrics.gap) {
                    // 几点那一列按这台的写法里最宽的两个时刻占宽（"上午 10:58""下午 10:58""10:58 PM"），各行对齐
                    ZStack(alignment: .leading) {
                        ForEach([10, 22], id: \.self) { Text(verbatim: ScheduleText.clock(hour: $0, minute: 58)).hidden() }
                        Text(verbatim: ScheduleText.time(line)).foregroundStyle(palette.ink)
                    }
                    .font(ScheduleMetrics.time).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: line.text).font(Typography.body).foregroundStyle(palette.ink)
                        Text(note).font(Typography.meta).foregroundStyle(palette.ink3)
                    }
                }
            }
        }
    }

    private func add() {
        guard CueMemoryLine.fits(text), draft.valid() else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines), schedule = draft
        workspace.attempt {
            try await workspace.noteCueLine(line, schedule: schedule)
            text = ""
            picking = false
            draft = ScheduleDraft()
            adding = true
        }
    }
}

/// 这一页一次读出的：定时与它们挂着的任务叫什么。
nonisolated private struct ScheduleShown: Equatable, Sendable {
    var schedules: [CueScheduled]
    var tasks: [UUID: String]

    static func read(_ store: isolated CueStore) throws -> ScheduleShown {
        let schedules = try store.cueSchedules()
        var tasks: [UUID: String] = [:]
        for id in Set(schedules.compactMap(\.line.task)) { tasks[id] = try store.card(id)?.heading }
        return ScheduleShown(schedules: schedules, tasks: tasks)
    }
}

/// 原地展开在改的那条定时与手上的那一份。
private struct Rescheduling: Equatable {
    let id: UUID
    var draft: ScheduleDraft
}

/// 一行的几点那一列：字号比正文大一档，与正文隔开一段。
private enum ScheduleMetrics {
    #if os(macOS)
    static let time = Typography.bodyStrong.weight(.medium)
    #else
    static let time = Font.system(.title3, weight: .medium)
    #endif
    static let gap: CGFloat = 14
}
