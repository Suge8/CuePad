#if os(macOS)
import CueBridge
import CueStore
import SwiftUI

struct AgentRows: View {
    var body: some View {
        ForEach(AgentKind.allCases) { AgentRow(kind: $0) }
    }
}

/// 出现时重新检测它：用户可能刚在终端里装好。
struct AgentRow: View {
    let kind: AgentKind
    @Environment(AppServices.self) private var services
    @State private var working = false
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case failed(String)
    }

    var body: some View {
        let status = services.agents.status(kind)
        let (tone, line) = describe(status)

        SettingRow(title: .verbatim(kind.name), icon: kind.mark.image, tone: tone, busy: working || installing, status: line, help: help) {
            // 开关常驻，检测完只换状态那一行字。
            Toggle(kind.name, isOn: Binding(get: { status?.isConnected ?? false }, set: apply))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(working || !(status.map(canToggle) ?? false))
        } fix: {
            if let status, Self.needsSetup(status), !installing {
                if let prerequisite = status.lacking {
                    Link("去官网", destination: prerequisite.site).settingFix().accessibilityLabel("\(prerequisite.name) 官网")
                } else {
                    Button(kind.facts.upgrades(status.presence) ? "升级" : "安装", action: install).settingFix()
                }
            }
        }
        .task { await services.agents.detect(kind) }
    }

    /// 开发构建不写真实配置目录；没装的 Agent 不接，但它卸掉后留下的 CuePad 技能能关掉删除。
    private func canToggle(_ status: AgentStatus) -> Bool {
        guard services.agents.isWritable(kind) else { return false }
        if case .foreign = status.files { return false }
        return status.isAvailable || status.files != .missing
    }

    private static func needsSetup(_ status: AgentStatus) -> Bool {
        switch status.presence {
        case .found: false
        case .tooOld: true
        case .unresponsive: false
        case .notFound: status.files == .missing
        }
    }

    private var installing: Bool { services.agents.jobs[kind] == .installing }

    private func describe(_ status: AgentStatus?) -> (StatusTone, Dotted?) {
        if case .failed(let message) = outcome { return (.failure, Dotted(message)) }
        if installing { return (.calm, Dotted(AgentLine.installing)) }
        if let status, Self.needsSetup(status) {
            if case .failed(let why) = services.agents.jobs[kind] { return (.failure, Dotted(AgentLine.notInstalled(why))) }
            if let prerequisite = status.lacking { return (.notice, Dotted(AgentLine.needs(prerequisite))) }
        }
        return AgentLine.of(kind, status, writable: services.agents.isWritable(kind))
    }

    /// 一句一行：中文句间不留空格、英文要，换行两边都对
    private var help: LocalizedStringResource {
        let files = services.agents.writtenFiles(kind).joined(separator: String(localized: "、"))
        let name = kind.name
        let shown = switch kind {
        case .pi: String(localized: "接入后，在终端里开的 \(name) 会话也出现在 CuePad 里：在 Mac 和手机上看它在做什么、发话、回答它的提问。")
        case .grok: String(localized: "接入后，在终端里开的 \(name) 会话也出现在 CuePad 里：在 Mac 和手机上看它在做什么。")
        case .dsh: String(localized: "CuePad 在后台开的 \(name) 会话出现在 CuePad 里；它的网页与桌面版里开的会话不接。")
        case .claudeCode, .codex, .opencode:
            String(localized: "接入后，在终端和桌面版里开的 \(name) 会话也出现在 CuePad 里：在 Mac 和手机上看它在做什么、发话、回答它的提问。")
        }
        let lines = [
            shown,
            kind == .pi ? String(localized: "CuePad 在后台开 Pi 会话也要先接入。") : String(localized: "不接入也能让 CuePad 在后台开 \(name) 会话。"),
            String(localized: "它也学会用 cuepad 记灵感、看和改任务，把页面和截图发到手机上看。"),
            kind == .codex ? String(localized: "Codex 在沙箱里跑命令，写入 CuePad 时会请你批准。") : nil,
            kind == .opencode ? String(localized: "会话直连 OpenCode 的后台服务，不用另装。") : nil,
            String(localized: "会写入 \(files)（配置文件里只加 CuePad 自己的条目）；关掉即删除。"),
            kind == .pi ? String(localized: "接入后运行中的会话 /reload 后生效。") : String(localized: "接入后新开的会话里生效。"),
            services.agents.status(kind).map { String(localized: "安装、升级在后台运行官方命令：\(kind.facts.installCommand($0.presence))") },
        ]
        return "\(lines.compactMap { $0 }.joined(separator: "\n"))"
    }

    private func apply(_ on: Bool) {
        working = true
        outcome = nil
        let agents = services.agents, kind = kind
        Task {
            defer { working = false }
            do {
                if on {
                    try await agents.install(kind)
                } else {
                    try await agents.uninstall(kind)
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
    }

    /// 没装上的原因在 `jobs` 里；这里接住的是装完重新检测、写进库时抛的错。
    private func install() {
        outcome = nil
        let services = services, kind = kind
        Task {
            do { try await services.installAgent(kind) } catch { outcome = .failed(error.localizedDescription) }
        }
    }
}

enum AgentLine {
    static var installing: String { String(localized: "安装中，可能要几分钟") }
    /// 原因是安装脚本的最后一句原话
    static func notInstalled(_ why: String) -> String { String(localized: "没装上：\(why)") }

    static func needs(_ prerequisite: InstallPrerequisite) -> String {
        let version = "\(prerequisite.minimum.major).\(prerequisite.minimum.minor)"
        return String(localized: "需要 \(prerequisite.name) \(version) 以上")
    }

    static func of(_ kind: AgentKind, _ status: AgentStatus?, writable: Bool) -> (StatusTone, Dotted?) {
        guard let status else { return (.calm, Dotted(String(localized: "检测中…"))) }
        guard writable else { return (.calm, Dotted(String(localized: "正式版在用，先用 \(kind.facts.homeVariable) 指定目录"))) }
        switch (status.presence, status.files) {
        case (_, .foreign(let path)): return (.failure, Dotted(String(localized: "\(path) 是别人的同名文件，没有改动")))
        case (.tooOld(let version), _) where kind == .opencode: return (.notice, Dotted(String(localized: "需要 OpenCode 2，现在是 \(version.description)")))
        case (.tooOld(let version), _): return (.notice, Dotted(String(localized: "\(version.description) 太旧，需要 \(kind.facts.minimumVersion.map(\.description) ?? "") 或更新")))
        case (.unresponsive, _): return (.notice, Dotted(String(localized: "找到了，但问版本没有回应，稍后再看")))
        case (.notFound, .missing): return (.calm, Dotted(String(localized: "没有检测到")))
        case (.notFound, _): return (.calm, Dotted(String(localized: "已卸载，CuePad 的技能还留着")))
        case (.found, .missing): return (.calm, Dotted(kind.writes))
        case (.found, .outdated): return (.notice, Dotted(String(localized: "需要升级")))
        case (.found(let version), .current): return (.calm, Dotted(String(localized: "已接入"), version.map { "\(kind.name) \($0)" }))
        }
    }
}

extension AgentKind {
    var writes: String {
        switch self {
        case .pi: String(localized: "写入扩展与技能")
        case .claudeCode, .codex: String(localized: "写入技能与钩子")
        case .opencode: String(localized: "写入技能，直连它的后台服务")
        case .grok: String(localized: "写入技能，跟读它的会话记录")
        case .dsh: String(localized: "写入技能")
        }
    }
}

#endif
