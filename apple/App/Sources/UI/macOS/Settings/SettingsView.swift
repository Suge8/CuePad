#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

/// 设置窗口的内容：只放会主动去改的（外观、Cue、通知、显示/隐藏与"对 Cue 说"的快捷键、自动检查更新）与几样连接各一行状态（iCloud、接入 Agent、命令行）。
/// 每一行都是 `SettingRow`；有事时那一行变色、状态后面给解决链接，细节在链接弹出的框里（`SettingPopover`），窗口本身不长出段落。
/// 窗口高度随内容、不滚动；回复框的快捷键在主菜单"回复"里，这里不重复。
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    /// "对 Cue 说"的快捷键（调试画面里没有）。
    @Environment(CueBar.self) private var cueBar: CueBar?
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section {
                SettingRow(title: "外观", icon: Image(.appearance)) {
                    Picker("外观", selection: $settings.theme) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ShortcutRow(title: "显示/隐藏", icon: .hotkey, accelerator: services.hotkey.accelerator, apply: services.hotkey.set)
                if let cueBar {
                    ShortcutRow(title: "对 Cue 说", icon: .talkToCue, accelerator: cueBar.hotkey.accelerator, apply: cueBar.hotkey.set)
                }
            }
            CueSettingsSection()
            if let alerts = services.alerts { NotificationSection(alerts: alerts) }
            Section {
                SyncRow()
                if !services.conflicts.isEmpty { ConflictsRow() }
            }
            Section {
                AgentRows()
                CommandLineToolRow()
            }
            Section {
                if let report = services.diagnostics.latest { CrashRow(report: report) }
                UpdateRow()
            }
        }
        .formStyle(.grouped)
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
        // 与主窗口同一种桌面色，不用系统的白底
        .background(palette.desk)
    }
}

/// 一个全局快捷键（显示/隐藏 CuePad、对 Cue 说）：点键帽后按下新的组合键，Esc 取消；注册失败时保留原快捷键，原因写在名称下面。
/// 悬停时键帽左边露出"更改"。
private struct ShortcutRow: View {
    let title: String
    let icon: Icon
    let accelerator: String
    /// 注册新的组合键；失败时抛出，原来的照用。
    let apply: (String) throws -> Void
    @Environment(\.palette) private var palette
    @State private var recording = false
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        SettingRow(title: title, icon: Image(icon), tone: error == nil ? .calm : .failure, status: error.map { Dotted($0) }) {
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 8) {
                    Text("更改").font(Typography.meta).foregroundStyle(palette.ink3)
                        .opacity(hovering && !recording ? 1 : 0)
                    Keycap(text: recording ? "请按下组合键…" : ShortcutText.display(accelerator))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
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

/// 通知：先一行系统权限（没决定过给"开启"，拒绝了给"打开系统设置"，开着时说横幅与专注模式在系统设置里调），
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
        let icon = Image(.alertsPending)
        switch alerts.authorization {
        case .notDetermined:
            SettingRow(title: "系统通知", icon: icon, tone: .notice, status: "还没开启") { EmptyView() } fix: {
                Button("开启") { Task { await alerts.requestAuthorization() } }.settingFix()
            }
        case .denied:
            SettingRow(title: "系统通知", icon: Image(.alertsOff), tone: .notice, status: "已关闭，收不到提示") { EmptyView() } fix: {
                Button("打开系统设置", action: openSystemSettings).settingFix()
            }
        default:
            SettingRow(title: "系统通知", icon: icon, status: "横幅样式与专注模式在系统设置里调") { EmptyView() }
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
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? AppServices.bundleID)")!)
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

/// 冲突副本：同一张卡在两台设备上离线改过。行里只说有几条，"处理…"弹出两个版本上下并排，选一份保留、另一份删除。
private struct ConflictsRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showing = false
    @State private var failure: String?

    var body: some View {
        SettingRow(
            title: "同步冲突", icon: Image(.conflict), tone: .notice,
            status: "\(services.conflicts.count) 条灵感或任务有两个版本"
        ) {
            EmptyView()
        } fix: {
            Button("处理…") { showing = true }
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
                            version("这台设备的版本", conflict.original, keep: .original, copy: conflict.copy.id)
                            version("另一台设备的版本", conflict.copy, keep: .copy, copy: conflict.copy.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure) }
        }
    }

    private func version(_ label: String, _ card: Card, keep choice: ConflictChoice, copy: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Dotted(label, DateLabel.short(card.modifiedAt))).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3)
                Spacer()
                Button("保留这一份") {
                    failure = nil
                    Task {
                        do { try await services.resolveConflict(copy: copy, keep: choice) } catch { failure = error.localizedDescription }
                    }
                }
                .settingButton()
            }
            Text(Outgoing.text(of: card)).font(Typography.secondary).foregroundStyle(palette.ink2)
                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .paper(radius: 10)
    }
}
#endif
