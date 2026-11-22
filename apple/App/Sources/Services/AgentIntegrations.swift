#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation
import Observation

@Observable
final class AgentIntegrations {
    private(set) var statuses: [AgentKind: AgentStatus] = [:]
    private(set) var jobs: [AgentKind: AgentJob] = [:]
    /// 在等你在浏览器里登录完的进程：再点一次登录先结束旧的（Codex 的登录占着固定端口）。
    @ObservationIgnored private var logins: [AgentKind: ChildProcess] = [:]

    var detected: Bool { statuses.count == AgentKind.allCases.count }
    @ObservationIgnored let integration: AgentIntegration

    init(_ integration: AgentIntegration) {
        self.integration = integration
    }

    func status(_ kind: AgentKind) -> AgentStatus? { statuses[kind] }

    func detect(_ kind: AgentKind) async {
        statuses[kind] = await integration.status(of: kind)
    }

    func executable(_ kind: AgentKind) async -> URL? {
        if statuses[kind] == nil { await detect(kind) }
        return statuses[kind]?.executable
    }

    func redetect() async {
        let integration = integration
        statuses = await withTaskGroup(of: (AgentKind, AgentStatus).self) { group in
            for kind in AgentKind.allCases { group.addTask { (kind, await integration.status(of: kind)) } }
            var found: [AgentKind: AgentStatus] = [:]
            for await (kind, status) in group { found[kind] = status }
            return found
        }
    }

    func installAgent(_ kind: AgentKind) async {
        jobs[kind] = .installing
        let result = await integration.runInstaller(kind, statuses[kind]?.presence ?? .notFound)
        await detect(kind)
        jobs[kind] = switch result {
        case nil: .failed(String(localized: "安装超时"))
        case let (status, output)? where status != 0: .failed(Self.lastLine(output) ?? String(localized: "安装没成功"))
        case _ where statuses[kind]?.isAvailable != true: .failed(String(localized: "装好了，但找不到 \(kind.facts.command)"))
        default: nil
        }
    }

    /// 再点一次就结束旧的、等它退出（放开 Codex 的固定端口）再重来。没登录成的记在 `jobs`。
    func logIn(_ kind: AgentKind) async {
        if let previous = logins.removeValue(forKey: kind) {
            previous.end()
            _ = await previous.waitForExit()
        }
        guard let executable = statuses[kind]?.executable else { return }
        jobs[kind] = .loggingIn
        do {
            let process = try await integration.startLogin(kind, executable: executable)
            logins[kind] = process
            let status = await process.waitForExit()
            guard logins[kind] === process else { return }
            logins[kind] = nil
            jobs[kind] = status == 0 ? nil : .failed(String(localized: "没登录成功"))
        } catch {
            jobs[kind] = .failed(error.localizedDescription)
        }
    }

    /// Pi 只能在它的终端界面里登录：开一个终端窗口跑 Pi（带上 CuePad 起它时的环境），你在里面输入 /login。
    func openPiLogin() async throws {
        guard let executable = statuses[.pi]?.executable else { return }
        let script = FileManager.default.temporaryDirectory.appending(path: "cuepad-pi-login.command")
        try await Data(integration.piLoginScript(executable: executable).utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    private static func lastLine(_ output: String) -> String? {
        output.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

extension AppServices {
    func installAgent(_ kind: AgentKind) async throws {
        await agents.installAgent(kind)
        try await macAgents.record(redetecting: true)
    }

    func isConnected(_ kind: AgentKind) -> Bool { settings.connectedAgents.contains(kind) }

    func connectAgents(_ kinds: some Sequence<AgentKind>) { settings.connectedAgents.formUnion(kinds) }

    func disconnectAgent(_ kind: AgentKind) { settings.connectedAgents.remove(kind) }

    var connectableAgents: [AgentKind] {
        AgentKind.allCases.filter { agents.integration.touches($0) && agents.status($0)?.isAvailable == true && !isConnected($0) }
    }

    func retireLegacySkill() {
        let integration = agents.integration
        guard let kinds = integration.legacySkillKinds() else { return }
        connectAgents(kinds)
        do {
            try integration.removeLegacySkill()
        } catch {
            reportIssue(.bridgeUnavailable(String(localized: "旧版 CuePad 写的技能没能删掉：\(error.localizedDescription)")))
        }
    }
}

enum AgentJob: Equatable {
    case installing
    case loggingIn
    case failed(String)
}
#endif
