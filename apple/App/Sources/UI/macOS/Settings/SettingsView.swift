#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueSync
import SwiftUI

/// 设置窗口的内容：外观、iCloud 同步与冲突副本、全局快捷键、投送、Pi 扩展。操作结果就地显示在对应行下。
struct SettingsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Form {
                Section("外观") {
                    Picker("主题", selection: $settings.theme) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    }
                    .pickerStyle(.segmented)
                }
                SyncSection()
                ConflictsSection()
                Section("快捷键") {
                    LabeledContent("显示或隐藏 CuePad") { ShortcutRecorder() }
                }
                Section {
                    Toggle("投送到其他应用后按回车", isOn: $settings.autoSubmit)
                    AccessibilityRow()
                } header: {
                    Text("投送")
                } footer: {
                    Text("投送到其他应用会写入剪贴板并在目标应用里粘贴，需要辅助功能授权；发给 Pi 会话不需要。")
                }
                Section {
                    PiExtensionRow()
                } header: {
                    Text("Pi")
                } footer: {
                    Text("扩展让 CuePad 看到 Pi 会话的实时状态，并把灵感和任务（含图片）直接发进会话。安装或升级后，已在运行的会话需要重启。")
                }
            }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear { services.accessibility.refresh() }
    }
}

/// 点击后按下新的组合键；Esc 取消。注册失败时保留原快捷键并显示原因。
private struct ShortcutRecorder: View {
    @Environment(AppServices.self) private var services
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? "请按下组合键…" : ShortcutText.display(services.settings.globalShortcut)) {
                recording ? stop() : start()
            }
            .monospaced()
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
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

private struct AccessibilityRow: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        LabeledContent("辅助功能") {
            if services.accessibility.isTrusted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                HStack {
                    Text("未授权").foregroundStyle(.secondary)
                    Button("授权…") { services.accessibility.request() }
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
    }
}

private struct PiExtensionRow: View {
    @Environment(AppServices.self) private var services
    @State private var working = false
    @State private var result: (text: String, failed: Bool)?

    var body: some View {
        let status = services.piExtension.status
        LabeledContent("Pi 版本") {
            switch status?.pi {
            case .none: Text("检测中…").foregroundStyle(.secondary)
            case .notFound: Text("没有找到 pi 命令").foregroundStyle(.secondary)
            case .found(_, let version):
                Text(version >= .minimumSupported ? "\(version)" : "\(version)（需要 \(PiVersion.minimumSupported) 或更新）")
                    .foregroundStyle(version >= .minimumSupported ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
            }
        }
        if let installation = status?.pi, !installation.isSupported {
            PiSetupGuide(installation: installation, showsTitle: false)
        }
        LabeledContent("CuePad 扩展") {
            HStack {
                Text(fileLabel(status?.file)).foregroundStyle(.secondary)
                if status?.pi.isSupported == true, needsInstall(status?.file) {
                    Button(status?.file == .missing ? "安装" : "升级", action: install).disabled(working)
                }
            }
        }
        if let result {
            Text(result.text).font(.caption).foregroundStyle(result.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private func fileLabel(_ file: PiExtensionFile?) -> String {
        switch file {
        case .none: ""
        case .missing: "未安装"
        case .current: "已是最新"
        case .outdated(let installed): "已安装旧版（v\(installed)）"
        case .foreign: "扩展目录里有同名的其他文件，未改动"
        }
    }

    private func needsInstall(_ file: PiExtensionFile?) -> Bool {
        switch file {
        case .missing, .outdated: true
        default: false
        }
    }

    private func install() {
        working = true
        Task {
            defer { working = false }
            do {
                try await services.piExtension.install()
                result = ("已安装；已在运行的 Pi 会话重启后生效", false)
            } catch {
                result = (error.localizedDescription, true)
            }
        }
    }
}

/// iCloud 同步：一行状态；暂停等你决定时给出两个选择（替换本机前再确认一次）。没有 iCloud 时只说明状态。
private struct SyncSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var confirmErase = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Section {
            if services.sync == nil {
                Label("这台 Mac 上的 CuePad 没有开启 iCloud 同步", systemImage: "icloud.slash").foregroundStyle(palette.ink3)
            } else {
                let summary = SyncSummary(services.syncStatus)
                LabeledContent {
                    if case .needsDecision = services.syncStatus {
                        EmptyView()
                    } else {
                        Button("立即同步") {
                            working = true
                            Task {
                                await services.syncNow()
                                working = false
                            }
                        }
                        .disabled(working || services.syncStatus == .syncing)
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title)
                            if let detail = summary.detail { Text(detail).font(.caption).foregroundStyle(palette.ink3) }
                        }
                    } icon: {
                        Image(systemName: summary.symbol).foregroundStyle(summary.color(palette))
                    }
                }
                if case .needsDecision = services.syncStatus {
                    HStack {
                        Button("上传本机数据") { resolve(.uploadLocal) }
                        Button("用云端数据替换本机…", role: .destructive) { confirmErase = true }
                    }
                    .disabled(working)
                }
                if !services.syncIssues.isEmpty {
                    DisclosureGroup("\(services.syncIssues.count) 条记录没能同步") {
                        ForEach(Array(services.syncIssues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).font(.caption).foregroundStyle(palette.ink3).textSelection(.enabled)
                        }
                    }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(palette.failure) }
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            if case .needsDecision = services.syncStatus {
                Text("上传：本机数据作为新内容传到当前账号。替换：丢弃本机的灵感、任务、项目与图片，从当前账号的云端重新下载。")
            }
        }
        .confirmationDialog("丢弃本机数据，改用云端的？", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("用云端数据替换本机", role: .destructive) { resolve(.eraseLocal) }
        } message: {
            Text("本机的灵感、任务、项目与图片会被删除，无法撤销。")
        }
    }

    private func resolve(_ resolution: SyncResolution) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do { try await services.resolveSync(resolution) } catch { failure = error.localizedDescription }
        }
    }
}

/// 冲突副本：同一张卡在两台设备上离线改过，两个版本上下并排，选一份保留，另一份删除。
private struct ConflictsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var failure: String?

    var body: some View {
        if !services.conflicts.isEmpty {
            Section {
                ForEach(services.conflicts, id: \.copy.id) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CardText(conflict.original.body).title.isEmpty ? "无标题" : CardText(conflict.original.body).title)
                            .font(.headline)
                        version("这台设备的版本", conflict.original, keep: .original, copy: conflict.copy.id)
                        version("另一台设备的版本", conflict.copy, keep: .copy, copy: conflict.copy.id)
                    }
                    .padding(.vertical, 4)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(palette.failure) }
            } header: {
                Text("\(services.conflicts.count) 条灵感或任务有两个版本")
            }
        }
    }

    private func version(_ label: String, _ card: Card, keep choice: ConflictChoice, copy: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(label) · \(DateLabel.short(card.modifiedAt))").font(.caption.weight(.medium)).foregroundStyle(palette.ink3)
                Spacer()
                Button("保留这一份") {
                    failure = nil
                    Task {
                        do { try await services.resolveConflict(copy: copy, keep: choice) } catch { failure = error.localizedDescription }
                    }
                }
                .controlSize(.small)
            }
            Text(Outgoing.text(of: card)).font(.system(size: 12.5)).foregroundStyle(palette.ink2)
                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .paper(radius: 10)
    }
}
#endif
