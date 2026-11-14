import CueStore
import SwiftUI

/// 不再定时先确认：库里是软删、界面上没有拨回去的路。
struct CueSchedulePage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: ScheduleShown?
    @State private var text = ""
    @State private var draft = ScheduleDraft()
    @State private var picking = DebugHooks.preset.scheduleOpen
    @State private var ending: CueMemoryLine?
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
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if picking {
                ScheduleEditor(text: "", draft: $draft, savable: CueMemoryLine.fits(text), save: add, cancel: { picking = false })
                    .padding(.top, Spacing.group)
            }
            HStack(spacing: Spacing.item) {
                Image(.add).font(Glyph.row).foregroundStyle(palette.ink2).readerHidden(true)
                TextField(String(localized: "到时候做什么"), text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("新定时")
                Button { picking.toggle() } label: {
                    let when = ScheduleText.when(draft)
                    Label { Text(verbatim: "\(when.day) \(when.time)") } icon: { Image(.schedule) }
                        .monospacedDigit()
                        .chip(on: picking, size: .compact)
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
            .padding(.vertical, Spacing.item)
        } else {
            let day = ScheduleText.days(line)
            let task = line.task.flatMap { shown?.tasks[$0] }.map { String(localized: "开工「\($0)」") }
            let late = item.last.flatMap { $0.late ? ScheduleText.missed($0) : nil }
            let note = Dotted(day, ScheduleText.overdue(line), task, late)
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
                    VStack(alignment: .leading, spacing: Spacing.hair) {
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

private struct Rescheduling: Equatable {
    let id: UUID
    var draft: ScheduleDraft
}

private enum ScheduleMetrics {
    #if os(macOS)
    static let time = Typography.bodyStrong.weight(.medium)
    #else
    static let time = Typography.title.weight(.medium)
    #endif
    static let gap = Spacing.group
}
