#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

/// 设置窗口的内容：只放会主动去改的（外观、显示/隐藏的快捷键、自动检查更新）与几样连接各一行状态（iCloud、Pi、命令行）。
/// 每一行都是 `SettingRow`；有事时那一行变色、状态后面给解决链接，细节在链接弹出的框里（`SettingPopover`），窗口本身不长出段落。
/// 窗口高度随内容、不滚动；回复框的快捷键在主菜单"回复"里，这里不重复。
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section {
                SettingRow(title: "外观", symbol: "sun.max") {
                    Picker("外观", selection: $settings.theme) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ShortcutRow()
            }
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

/// 显示/隐藏 CuePad 的全局快捷键：点键帽后按下新的组合键，Esc 取消；注册失败时保留原快捷键，原因写在名称下面。悬停时键帽左边露出"更改"。
private struct ShortcutRow: View {
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var recording = false
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        SettingRow(title: "显示/隐藏", symbol: "keyboard", tone: error == nil ? .calm : .failure, status: error.map { Dotted($0) }) {
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 8) {
                    Text("更改").font(Typography.meta).foregroundStyle(palette.ink3)
                        .opacity(hovering && !recording ? 1 : 0)
                    Keycap(text: recording ? "请按下组合键…" : ShortcutText.display(services.settings.globalShortcut))
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
            try services.setGlobalShortcut(accelerator)
        } catch HotkeyError.occupied {
            error = "这个组合已被其他应用占用"
        } catch {
            self.error = "无法注册：\(error)"
        }
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
            title: report.kind.label, symbol: "exclamationmark.triangle", tone: .notice,
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
            title: "同步冲突", symbol: "square.on.square", tone: .notice,
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
