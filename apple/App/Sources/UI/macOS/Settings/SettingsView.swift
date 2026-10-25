#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// 设置窗口的两页，工具栏上一排标签切换（同系统各应用的设置窗口），按要紧排：
/// 通用（Cue 的名字与在哪台运行、iCloud、通知、外观与快捷键、更新）、Agent（接入哪几家与 cuepad 命令，接好就很少再来）。
enum SettingsPane: String, CaseIterable {
    case general, agents

    var title: String {
        switch self {
        case .general: "通用"
        case .agents: "Agent"
        }
    }

    var icon: Icon {
        switch self {
        case .general: .settings
        case .agents: .agent
        }
    }

    /// 打开设置窗口；给了 `pane` 就翻到那一页，否则停在上次那一页。
    static func open(_ pane: SettingsPane? = nil) {
        NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: pane)
    }
}

/// 设置窗口的一页：只放会主动去改的与几样连接各一行状态。每一行都是 `SettingRow`；有事时那一行变色、状态后面给解决链接，
/// 细节在链接弹出的框里（`SettingPopover`），窗口本身不长出段落。窗口高度随这一页的内容、不滚动；回复框的快捷键在主菜单"回复"里，这里不重复。
struct SettingsView: View {
    let pane: SettingsPane
    @Environment(\.palette) private var palette

    var body: some View {
        WholePointHeight {
            form
        }
        .frame(width: 520)
        // 与主窗口同一种桌面色，不用系统的白底
        .background(palette.desk)
    }

    private var form: some View {
        Form {
            switch pane {
            case .general: GeneralSections()
            case .agents:
                Section {
                    AgentRows()
                    CommandLineToolRow()
                }
            }
        }
        .formStyle(.grouped)
        .font(Typography.body)
        .scrollContentBackground(.hidden)
    }
}

/// 这一页按内容的理想高度排、高度进到整点：窗口只能是整点高，半点高的内容（行高常是 x.5）让窗口进位后，
/// 表单的滚动区按进位后的窗口让出半点上下边距、内容又按整点排，多出半点可滚，窗口一出现滚动条就闪出来。
private struct WholePointHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: ideal.height.rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// 通用那一页：Cue（`CueSettingsSection`）、iCloud 同步（与冲突）、通知、外观与两个全局快捷键、更新（与上次崩溃）。
private struct GeneralSections: View {
    @Environment(AppServices.self) private var services
    /// "对 Cue 说"的快捷键（调试画面里没有）。
    @Environment(CueBar.self) private var cueBar: CueBar?

    var body: some View {
        CueSettingsSection()
        Section {
            SyncRow()
            if !services.conflicts.isEmpty { ConflictsRow() }
        }
        if let alerts = services.alerts { NotificationSection(alerts: alerts) }
        Section {
            SettingRow(title: "外观", icon: Image(.appearance)) { ThemePicker() }
            ShortcutRow(title: "显示/隐藏", icon: .hotkey, accelerator: services.hotkey.accelerator, apply: services.hotkey.set)
            if let cueBar {
                ShortcutRow(title: "对 Cue 说", icon: .talkToCue, accelerator: cueBar.hotkey.accelerator, apply: cueBar.hotkey.set)
            }
        }
        Section {
            if let report = services.diagnostics.latest { CrashRow(report: report) }
            UpdateRow()
        }
    }
}

/// 一个全局快捷键（显示/隐藏 CuePad、对 Cue 说）：点键帽后按下新的组合键，Esc 取消；注册失败时保留原快捷键，原因写在名称下面。
/// 快捷键那一格：指针停在上面（`buttonHovered`）时左边露出"更改"（占着位置、只是透明，露出时键帽不挪）。
private struct ShortcutKey: View {
    let text: String
    let recording: Bool
    @Environment(\.buttonHovered) private var lit
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text("更改").font(Typography.meta).foregroundStyle(palette.ink3).opacity(lit && !recording ? 1 : 0)
            Keycap(text: text)
        }
        .contentShape(.rect)
    }
}

private struct ShortcutRow: View {
    let title: String
    let icon: Icon
    let accelerator: String
    /// 注册新的组合键；失败时抛出，原来的照用。
    let apply: (String) throws -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        SettingRow(title: title, icon: Image(icon), tone: error == nil ? .calm : .failure, status: error.map { Dotted($0) }) {
            Button { recording ? stop() : start() } label: {
                ShortcutKey(text: recording ? "请按下组合键…" : ShortcutText.display(accelerator), recording: recording)
            }
            .buttonStyle(PressStyle(.inline))
            .help("点一下，按下新的组合键（Esc 取消）")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        error = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private static let escape: UInt16 = 53

    private func capture(_ event: NSEvent) {
        defer { stop() }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == Self.escape && flags.isEmpty { return }
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard !modifiers.isEmpty, let accelerator = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers).accelerator else {
            error = "需要至少一个修饰键加字母、数字、空格或功能键"
            return
        }
        do {
            try apply(accelerator)
        } catch HotkeyError.occupied {
            error = "这个组合已被其他应用占用"
        } catch {
            self.error = "无法注册：\(error)"
        }
    }
}

/// 通知：系统权限没开时先一行（没决定过给"开启"，拒绝了给"打开系统设置"；开着就不占一行，横幅样式本来就在系统设置里），
/// 再是两种提示（`AlertRoute.kind`）各一行：开关与提示音（选中即试听一次）。关掉一种 = 它的横幅与声音都没有。
private struct NotificationSection: View {
    let alerts: AlertCenter
    @Environment(AppServices.self) private var services

    var body: some View {
        Section {
            permission
            row("等你", kind: .waitingForUser, help: "Agent 在等你回答或确认，Cue 带选项来问你或有急事")
            row("做完了", kind: .settled, help: "Agent 做完了一轮")
        }
        .task { await alerts.refresh() }
    }

    @ViewBuilder private var permission: some View {
        switch alerts.authorization {
        case .notDetermined:
            SettingRow(title: "系统通知", icon: Image(.alertsPending), tone: .notice, status: "还没开启") { EmptyView() } fix: {
                Button("开启") { Task { await alerts.requestAuthorization() } }.settingFix()
            }
        case .denied:
            SettingRow(title: "系统通知", icon: Image(.alertsOff), tone: .notice, status: "已关闭，收不到提示") { EmptyView() } fix: {
                Button("打开系统设置", action: openSystemSettings).settingFix()
            }
        default:
            EmptyView()
        }
    }

    private func row(_ title: String, kind: PiAlert, help: String) -> some View {
        @Bindable var settings = services.settings
        // 设置行的图标是墨色线条：形状与提示带的状态图形同一个
        return SettingRow(title: title, icon: Image(PiShown(status: SessionAlert.status(kind)).icon), help: help) {
            HStack(spacing: 12) {
                Picker("提示音", selection: Binding(get: { settings.alerts[kind].sound }, set: { sound in
                    settings.alerts[kind].sound = sound
                    sound?.preview()
                })) {
                    Text("无").tag(AlertSound?.none)
                    Divider()
                    ForEach(AlertSound.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.alerts[kind].isOn)
                Toggle(title, isOn: $settings.alerts[kind].isOn).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.id)")!)
    }
}

enum ShortcutText {
    private static let symbols = ["Control": "⌃", "Alt": "⌥", "Shift": "⇧", "Super": "⌘"]

    /// `Alt+Space` → `⌥ Space`，`Super+KeyK` → `⌘K`。
    static func display(_ accelerator: String) -> String {
        let parts = accelerator.split(separator: "+").map(String.init)
        guard let key = parts.last else { return accelerator }
        let modifiers = parts.dropLast().map { symbols[$0] ?? $0 }.joined()
        let name = key.hasPrefix("Key") ? String(key.dropFirst(3)) : key.hasPrefix("Digit") ? String(key.dropFirst(5)) : key
        return modifiers + (name.count > 1 ? " \(name)" : name)
    }
}

/// 上次崩溃：要你注意的一行，"查看"弹出摘要与导出（启动参数 `-CuePadCrashSheet` 时一打开就弹）。
private struct CrashRow: View {
    let report: CrashReport
    @State private var showing = DebugHooks.preset.crashSheet

    var body: some View {
        SettingRow(
            title: report.kind.label, icon: Image(.failure), tone: .failure,
            status: Dotted(report.date.formatted(date: .abbreviated, time: .shortened))
        ) {
            EmptyView()
        } fix: {
            Button("查看") { showing = true }
                .settingFix()
                .popover(isPresented: $showing, arrowEdge: .bottom) { CrashReportView(report: report) }
        }
    }
}

/// 冲突副本：同一张卡在两台设备上离线改过。行里只说有几条，"选一份…"弹出两个版本上下并排，选一份保留、另一份删除
/// （不叫"处理…"：同步要你决定时 iCloud 那一行也有"处理…"，同一屏两个同名链接分不清）。
private struct ConflictsRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showing = false
    @State private var choices = SyncChoices()

    var body: some View {
        SettingRow(
            title: "同步冲突", icon: Image(.conflict), tone: .notice,
            status: "\(services.conflicts.count) 条灵感或任务有两个版本"
        ) {
            EmptyView()
        } fix: {
            Button("选一份…") { showing = true }
                .settingFix()
                .popover(isPresented: $showing, arrowEdge: .bottom) { versions }
        }
        .onChange(of: services.conflicts.isEmpty) { _, empty in if empty { showing = false } }
    }

    private var versions: some View {
        SettingPopover(title: "选一份保留", width: 420) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(services.conflicts, id: \.copy.id) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(CardText(conflict.original.body).label).font(Typography.bodyStrong)
                            ForEach(conflict.versions) { version($0, of: conflict) }
                        }
                    }
                }
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
            if let failure = choices.failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure) }
        }
    }

    private func version(_ version: ConflictVersion, of conflict: CardConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Dotted(version.label, DateLabel.short(version.card.modifiedAt))).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3)
                Spacer()
                Button(SyncChoices.keep) { choices.keep(version.keep, of: conflict, services) }
                    .settingButton()
                    .disabled(choices.working)
            }
            Text(Outgoing.text(of: version.card)).font(Typography.secondary).foregroundStyle(palette.ink2)
                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .paper(radius: 10)
    }
}
#endif
