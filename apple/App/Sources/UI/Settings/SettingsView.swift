#if os(macOS)
import AppKit
import CuePi
import SwiftUI

/// 设置窗口的内容：主题、全局快捷键、投送后回车、辅助功能授权、Pi 扩展。操作结果就地显示在对应行下。
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
                    Text("扩展让 CuePad 看到 Pi 会话的实时状态，并把卡片（含图片）直接发进会话。安装或升级后，已在运行的会话需要重启。")
                }
            }
        .formStyle(.grouped)
        .frame(width: 500, height: 580)
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
        LabeledContent("Pi") {
            switch status?.pi {
            case .none: Text("检测中…").foregroundStyle(.secondary)
            case .notFound: Text("没有找到 pi 命令").foregroundStyle(.secondary)
            case .found(_, let version):
                Text(version >= .minimumSupported ? "\(version)" : "\(version)（需要 \(PiVersion.minimumSupported) 或更新）")
                    .foregroundStyle(version >= .minimumSupported ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
            }
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
                result = (ErrorText.describe(error), true)
            }
        }
    }
}
#endif
