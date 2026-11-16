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
            Toggle(kind.name, isOn: Binding(get: { services.isConnected(kind) }, set: apply))
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

    /// 开发构建不读真实配置目录里的会话；没装的 Agent 不接，接过的卸掉后还能关掉。
    private func canToggle(_ status: AgentStatus) -> Bool {
        services.agents.integration.touches(kind) && (status.isAvailable || services.isConnected(kind))
    }

    private static func needsSetup(_ status: AgentStatus) -> Bool {
        switch status.presence {
        case .found, .unresponsive: false
        case .tooOld, .notFound: true
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
        return AgentLine.of(kind, status, connected: services.isConnected(kind), touches: services.agents.integration.touches(kind))
    }

    /// 一句一行：中文句间不留空格、英文要，换行两边都对
    private var help: LocalizedStringResource {
        let name = kind.name
        let lines = [
            kind.readsAllSessions
                ? String(localized: "接入后，这台 Mac 上的 \(name) 会话记录都能在 CuePad 里翻看，终端里开的也在；对其中一个发话，CuePad 在后台接着它。")
                : kind == .dsh ? String(localized: "CuePad 里只有它在后台开过的 \(name) 会话，网页与桌面版里开的不会出现。")
                : String(localized: "CuePad 里只有它在后台开过的 \(name) 会话，终端里开的不会出现。"),
            String(localized: "不接入也能让 CuePad 在后台开 \(name) 会话。"),
            String(localized: "CuePad 开的会话都知道用 cuepad 把页面、文档和截图发到你手机上看。"),
            kind == .codex ? String(localized: "Codex 在沙箱里跑命令，写入 CuePad 时会请你批准。") : nil,
            kind == .opencode ? String(localized: "会话直连 OpenCode 的后台服务，不用另装。") : nil,
            services.agents.status(kind).map { String(localized: "安装、升级在后台运行官方命令：\(kind.facts.installCommand($0.presence))") },
        ]
        return "\(lines.compactMap { $0 }.joined(separator: "\n"))"
    }

    private func apply(_ on: Bool) {
        outcome = nil
        guard !on else { return services.connectAgents([kind]) }
        working = true
        let services = services, kind = kind
        Task {
            await services.disconnectAgent(kind)
            working = false
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

    /// `touches`：这家的配置目录碰得到（`AgentIntegration.touches`）。
    static func of(_ kind: AgentKind, _ status: AgentStatus?, connected: Bool, touches: Bool) -> (StatusTone, Dotted?) {
        guard let status else { return (.calm, Dotted(String(localized: "检测中…"))) }
        guard touches else { return (.calm, Dotted(String(localized: "正式版在用，先用 \(kind.facts.homeVariable) 指定目录"))) }
        switch status.presence {
        case .tooOld(let version) where kind == .opencode: return (.notice, Dotted(String(localized: "需要 OpenCode 2，现在是 \(version.description)")))
        case .tooOld(let version): return (.notice, Dotted(String(localized: "\(version.description) 太旧，需要 \(kind.facts.minimumVersion.map(\.description) ?? "") 或更新")))
        case .unresponsive: return (.notice, Dotted(String(localized: "找到了，但问版本没有回应，稍后再看")))
        case .notFound: return (.calm, Dotted(String(localized: "没有检测到")))
        case .found(let version) where connected: return (.calm, Dotted(String(localized: "已接入"), version.map { "\(kind.name) \($0)" }))
        case .found: return (.calm, kind.readsAllSessions ? Dotted(String(localized: "读进它的会话记录")) : nil)
        }
    }
}

extension AgentKind {
    /// 接入后读进它磁盘上的全部会话记录（`HistoryScope.all`）。OpenCode 只认 CuePad 托管过的（`OpenCodeRuntime`），
    /// dsh 的会话记录只落在 CuePad 给托管会话的存储根里（`DshRuntime.sessions`）。
    var readsAllSessions: Bool { self != .opencode && self != .dsh }
}

#endif
