import CueStore
import SwiftUI

/// 改一条定时时手上的那一份（`ScheduleEditor`）：一次（哪天几点）、每天、每周几、每月几号，与几点。改的就是记忆里那一条（`CueMemoryLine`）。
struct ScheduleDraft: Equatable {
    enum Cycle: CaseIterable, Hashable {
        case once, daily, weekly, monthly

        var title: LocalizedStringResource {
            switch self {
            case .once: "一次"
            case .daily: "每天"
            case .weekly: "每周"
            case .monthly: "每月"
            }
        }
    }

    var cycle: Cycle
    /// 一次的哪天几点；重复的只取几点
    var date: Date
    /// 每周的哪几天（`Calendar` 的 weekday：1 是周日）
    var weekdays: Set<Int>
    var monthDay: Int

    /// 照一条定时摆好；新建的从下一个整点起、只这一次。
    init(_ line: CueMemoryLine? = nil, now: Date = .now) {
        let calendar = Calendar.current
        let hourLater = now.addingTimeInterval(3600)
        var date = line?.remindAt ?? calendar.date(bySetting: .minute, value: 0, of: hourLater) ?? hourLater
        let rule = line?.repeats
        if let rule { date = calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: date) ?? date }
        self.date = date
        weekdays = [calendar.component(.weekday, from: date)]
        monthDay = calendar.component(.day, from: date)
        switch rule?.cycle {
        case nil: cycle = .once
        case .daily: cycle = .daily
        case .weekly(let days):
            cycle = .weekly
            weekdays = days
        case .monthly(let day):
            cycle = .monthly
            monthDay = day
        }
    }

    var repeats: CueRepeat? {
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        let (hour, minute) = (time.hour ?? 0, time.minute ?? 0)
        return switch cycle {
        case .once: nil
        case .daily: CueRepeat(.daily, hour: hour, minute: minute)
        case .weekly: CueRepeat(.weekly(weekdays), hour: hour, minute: minute)
        case .monthly: CueRepeat(.monthly(monthDay), hour: hour, minute: minute)
        }
    }

    /// 下一次（存进 `remindAt`）。
    func next(after now: Date = .now) -> Date { repeats?.next(after: now) ?? date }

    /// 定得成：一次的要在以后，每周的至少选一天。
    func valid(now: Date = .now) -> Bool {
        switch cycle {
        case .once: date > now
        case .weekly: !weekdays.isEmpty
        case .daily, .monthly: true
        }
    }
}

/// 原地改一条定时（任务气泡里点"改"、定时页里改一条或点新定时的几点）：同一块原地展开，不另开一页。
/// 从上到下：标题"定时"与取消、好；改的是哪一条；一次｜每天｜每周｜每月；按它选哪天（每周几、每月几号、一次的日期）；几点；
/// 最下面一行写改完的下一次在哪台 Mac 上（定时到点由那台 Mac 上的 Cue 开工），已有的定时右边是"不再定时"。
struct ScheduleEditor: View {
    let text: String
    /// 手上的那一份归调用方：点"好"与调用方自己的提交（"记一条"按回车）存的是同一份
    @Binding var draft: ScheduleDraft
    /// 调用方那边存得成（新记一条时正文记得成）：不成时"好"停用
    var savable = true
    let save: () -> Void
    let cancel: () -> Void
    /// 已有的定时才有：点"不再定时"，由调用方先确认（`stopScheduleDialog`）
    var end: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("定时", icon: .schedule).font(BubbleMetrics.strong).foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                Button("取消", action: cancel).buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink2)
                Button(action: save) {
                    Text("好").font(BubbleMetrics.meta.weight(.semibold)).foregroundStyle(palette.onFill)
                        .padding(.horizontal, 14).frame(height: BubbleMetrics.capsule)
                        .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .disabled(!savable || !draft.valid())
                .opacity(savable && draft.valid() ? 1 : ControlMetrics.disabledOpacity)
            }
            if !text.isEmpty {
                Text(verbatim: text).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(2)
            }
            Picker("重复", selection: $draft.cycle) {
                ForEach(ScheduleDraft.Cycle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            day
            DatePicker("时刻", selection: $draft.date, displayedComponents: .hourAndMinute)
                #if os(iOS)
                .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity).frame(height: Self.wheelHeight).clipped()
                #else
                .datePickerStyle(.stepperField)
                #endif
            HStack(spacing: 6) {
                Image(.mac).foregroundStyle(palette.ink3)
                Text(Dotted(String(localized: "下一次：\(ScheduleText.moment(draft.next()))"), workspace.cue.hostName ?? MacAgents.unnamed))
                    .foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 8)
                if let end {
                    Button("不再定时", action: end).buttonStyle(PressStyle(.inline)).foregroundStyle(palette.failure)
                }
            }
            .font(BubbleMetrics.meta)
        }
        .padding(BubbleMetrics.stripPadding)
        .background(palette.fill, in: Radius.nested)
    }

    /// 选哪天：每周几一排圆钮（周一在前），每月几号一个菜单，一次的是日期；每天的没有这一行。
    @ViewBuilder private var day: some View {
        switch draft.cycle {
        case .daily: EmptyView()
        case .once:
            DatePicker("日期", selection: $draft.date, in: Date.now..., displayedComponents: .date)
        case .monthly:
            Picker("每月几号", selection: $draft.monthDay) {
                ForEach(1...31, id: \.self) { Text("\($0) 号").tag($0) }
            }
            .pickerStyle(.menu)
        case .weekly:
            HStack(spacing: 6) {
                ForEach(ScheduleText.weekOrder, id: \.self) { weekday in WeekdayChip(weekday: weekday, days: $draft.weekdays) }
            }
        }
    }

    #if os(iOS)
    /// 时刻的滚轮露几行：够看清上下各两格
    private static let wheelHeight: CGFloat = 150
    #endif
}

/// 每周几的一颗圆钮：选中的描一圈靛青、铺选中底，读屏念全名与选没选。
private struct WeekdayChip: View {
    let weekday: Int
    @Binding var days: Set<Int>
    @Environment(\.palette) private var palette

    var body: some View {
        let on = days.contains(weekday)
        Button {
            if on { days.remove(weekday) } else { days.insert(weekday) }
        } label: {
            Text(verbatim: Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                .font(BubbleMetrics.meta.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? palette.signature : palette.ink2)
                .frame(maxWidth: .infinity).frame(height: BubbleMetrics.capsule)
                .background(on ? palette.selection : palette.fill, in: .circle)
                .overlay { if on { Circle().strokeBorder(palette.signature, lineWidth: 1) } }
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 任务气泡里的一条定时：几点怎么重复，下一次在哪台 Mac 上，上一次错过后补上的那句事实；右边"改"原地展开成 `ScheduleEditor`。
/// 与下面会话那一条（`AgentStrip`）同一种底、同一种圆角。
struct ScheduleStrip: View {
    let scheduled: CueScheduled
    /// 在改时手上的那一份；nil 是没在改
    @State private var draft: ScheduleDraft?
    @State private var ending: CueMemoryLine?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    init(scheduled: CueScheduled) {
        self.scheduled = scheduled
        _draft = State(initialValue: DebugHooks.preset.scheduleOpen ? ScheduleDraft(scheduled.line) : nil)
    }

    var body: some View {
        let line = scheduled.line, id = line.id
        if let editing = draft {
            ScheduleEditor(
                text: "", draft: Binding { draft ?? editing } set: { draft = $0 },
                save: {
                    workspace.rescheduleCueLine(id, draft ?? editing)
                    draft = nil
                },
                cancel: { draft = nil }, end: { ending = line })
            .transition(.opacity)
            .stopScheduleDialog($ending)
        } else {
            HStack(alignment: .top, spacing: BubbleMetrics.gap) {
                Image(.schedule).font(.system(size: BubbleMetrics.brand * 0.8)).foregroundStyle(palette.ink2).frame(width: BubbleMetrics.markSlot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.repeats == nil ? line.remindAt.map { ScheduleText.moment($0) } ?? "" : ScheduleText.repeats(line.repeats))
                        .font(BubbleMetrics.strong).foregroundStyle(palette.ink)
                    Text(next).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(2)
                    if let last = scheduled.last, last.late {
                        Text(ScheduleText.missed(last)).font(BubbleMetrics.meta).foregroundStyle(palette.ink3).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Button { draft = ScheduleDraft(line) } label: {
                    Text("改").font(BubbleMetrics.meta.weight(.semibold)).foregroundStyle(palette.ink)
                        .padding(.horizontal, 14).frame(height: BubbleMetrics.capsule)
                        .background(palette.fill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("改定时")
            }
            .padding(BubbleMetrics.stripPadding)
            .background(palette.fill, in: Radius.nested)
            .accessibilityElement(children: .combine)
        }
    }

    /// "下一次：周一 9:00 · 在 Mac Studio"；一次性的写"只这一次"。
    private var next: Dotted {
        let host = String(localized: "在 \(workspace.cue.hostName ?? MacAgents.unnamed)")
        guard scheduled.line.repeats != nil, let at = scheduled.line.remindAt else { return Dotted(String(localized: "只这一次"), host) }
        return Dotted(String(localized: "下一次：\(ScheduleText.moment(at))"), host)
    }
}

extension View {
    /// 不再定时先确认（库里忘掉是软删，界面上没有拨回去的路）：`line` 设上就问，点了才忘掉这一条。
    func stopScheduleDialog(_ line: Binding<CueMemoryLine?>) -> some View { modifier(StopScheduleDialog(line: line)) }
}

private struct StopScheduleDialog: ViewModifier {
    @Binding var line: CueMemoryLine?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.dialog("不再定时？", item: $line, message: "到点不再叫醒 \(workspace.cue.name)，找不回来") { line in
            [DialogButton(title: "不再定时", role: .destructive) { workspace.forgetCueLine(line.id) }]
        }
    }
}
