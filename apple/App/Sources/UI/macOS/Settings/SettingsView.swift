#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueSync
import SwiftUI

/// 设置窗口的内容：外观、iCloud 同步与冲突副本、全局快捷键、Pi 扩展、命令行、更新——都是同一种分组卡。操作结果就地显示在对应行下。
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        form
        .frame(width: 520)
        // 与主窗口同一种桌面色，不用系统的白底
        .background(palette.desk)
    }

    private var form: some View {
        @Bindable var settings = services.settings
        return Form {
            Section {
                Picker("主题", selection: $settings.theme) {
                    Text("跟随系统").tag(AppSettings.Theme.system)
                    Text("浅色").tag(AppSettings.Theme.light)
                    Text("深色").tag(AppSettings.Theme.dark)
                }
                .pickerStyle(.segmented)
            } header: {
                SettingsHeader("外观")
            }
            SyncSection()
            ConflictsSection()
            Section {
                LabeledContent("显示或隐藏 CuePad") { ShortcutRecorder() }
                ForEach(ReplyShortcut.allCases, id: \.self) { key in
                    LabeledContent {
                        Keycap(text: key.symbols)
                    } label: {
                        Text(key.title)
                        Text(key.explanation)
                    }
                }
            } header: {
                SettingsHeader("快捷键")
            }
            if services.diagnostics.latest != nil { Section { LastCrashRow() } header: { SettingsHeader("诊断") } }
            Section {
                PiExtensionRow()
            } header: {
                SettingsHeader("Pi")
            } footer: {
                SettingsFooter("扩展让 CuePad 看到 Pi 会话的实时状态，并把提示词（含图片）直接发进会话；技能让 Agent 知道怎么把页面和截图发到手机上看。安装或升级后，已在运行的会话在终端里执行 /reload 就能用上。")
            }
            Section { CommandLineToolRow() } header: { SettingsHeader("命令行") }
            Section { UpdateRow() } header: { SettingsHeader("更新") }
        }
        .formStyle(.grouped)
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .frame(height: 720)
    }
}

/// 分组标题：比行小一号的次要墨色，行才是这一页的主体（同一号粗体时分不出层级）。
private struct SettingsHeader: View {
    let title: String
    @Environment(\.palette) private var palette

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(Typography.label).foregroundStyle(palette.ink3).padding(.top, 6)
    }
}

/// 分组下面的说明：元信息字号的次要墨色。
private struct SettingsFooter: View {
    let text: String
    @Environment(\.palette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Typography.meta).foregroundStyle(palette.ink3)
    }
}

/// 点击后按下新的组合键；Esc 取消。注册失败时保留原快捷键并显示原因。键帽与其余快捷键同一种，悬停时左边露出"更改"。
private struct ShortcutRecorder: View {
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var recording = false
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
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
            if let error { Text(error).font(Typography.meta).foregroundStyle(palette.failure) }
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

private struct PiExtensionRow: View {
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var working = false
    @State private var result: (text: String, failed: Bool)?

    var body: some View {
        let status = services.piIntegration.status
        LabeledContent("Pi 版本") {
            switch status?.pi {
            case .none: Text("检测中…").foregroundStyle(.secondary)
            case .notFound: Text("没有找到 pi 命令").foregroundStyle(.secondary)
            case .found(_, let version):
                Text(version >= .minimumSupported ? "\(version)" : "\(version)（需要 \(PiVersion.minimumSupported) 或更新）")
                    .foregroundStyle(version >= .minimumSupported ? AnyShapeStyle(.primary) : AnyShapeStyle(palette.failure))
            }
        }
        if let installation = status?.pi, !installation.isSupported {
            PiSetupGuide(installation: installation, showsTitle: false)
        }
        LabeledContent("CuePad 扩展与技能") {
            HStack {
                Text(fileLabel(status?.file)).foregroundStyle(.secondary)
                if status?.pi.isSupported == true, needsInstall(status?.file) {
                    Button(status?.file == .missing ? "安装" : "升级", action: install).disabled(working)
                }
            }
        }
        if let result {
            Text(result.text).font(Typography.meta).foregroundStyle(result.failed ? AnyShapeStyle(palette.failure) : AnyShapeStyle(.secondary))
        }
    }

    private func fileLabel(_ file: PiIntegrationFile?) -> String {
        switch file {
        case .none: ""
        case .missing: "未安装"
        case .current: "已是最新"
        case .outdated(let installed): "已安装旧版（v\(installed)）"
        case .foreign: "扩展或技能目录里有同名的其他文件，未改动"
        }
    }

    private func needsInstall(_ file: PiIntegrationFile?) -> Bool {
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
                try await services.piIntegration.install()
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
                            if let detail = summary.detail { Text(detail).font(Typography.meta).foregroundStyle(palette.ink3) }
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.summary).font(Typography.meta)
                                Text(issue.message).font(Typography.meta.monospaced()).foregroundStyle(palette.ink3).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure) }
            }
        } header: {
            SettingsHeader("iCloud 同步")
        } footer: {
            if case .needsDecision = services.syncStatus {
                SettingsFooter("上传：本机数据作为新内容传到当前账号。替换：丢弃本机的灵感、任务、项目与图片，从当前账号的云端重新下载。")
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
                        Text(CardText(conflict.original.body).label)
                            .font(Typography.bodyStrong)
                        version("这台设备的版本", conflict.original, keep: .original, copy: conflict.copy.id)
                        version("另一台设备的版本", conflict.copy, keep: .copy, copy: conflict.copy.id)
                    }
                    .padding(.vertical, 4)
                }
                if let failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure) }
            } header: {
                SettingsHeader("\(services.conflicts.count) 条灵感或任务有两个版本")
            }
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
                .controlSize(.small)
            }
            Text(Outgoing.text(of: card)).font(Typography.secondary).foregroundStyle(palette.ink2)
                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .paper(radius: 10)
    }
}
#endif
