#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation
import Observation

/// `AgentIntegration` 之上唯一的一份。装只在用户点了之后；装过的在 `refresh()` 发现与这个版本的 App 要写的不同时
/// （App 更新了，或 App 被移动后技能里的 cuepad 路径变了）静默升级，不再询问。
/// 不碰真实世界时（`LibraryLocation.touchesRealWorld`）只写配置目录经环境变量换走了的那几家（`AgentIntegration.isWritable`），其余只检测。
@Observable
final class AgentIntegrations {
    private(set) var statuses: [AgentKind: AgentStatus] = [:]
    /// 在后台装、登录的那几家（接入面板的"安装""登录"）与没做成的原因；做成了就没有这一项，之后看检测与探测。
    private(set) var jobs: [AgentKind: AgentJob] = [:]
    /// 在等你在浏览器里登录完的进程：再点一次登录先结束旧的（Codex 的登录占着固定端口）。
    @ObservationIgnored private var logins: [AgentKind: ChildProcess] = [:]

    var detected: Bool { statuses.count == AgentKind.allCases.count }
    @ObservationIgnored let integration: AgentIntegration
    @ObservationIgnored var uninstalled: (AgentKind) async -> Void = { _ in }
    @ObservationIgnored var installed: (AgentKind) -> Void = { _ in }

    init(_ integration: AgentIntegration) {
        self.integration = integration
    }

    func status(_ kind: AgentKind) -> AgentStatus? { statuses[kind] }

    func isWritable(_ kind: AgentKind) -> Bool { integration.isWritable(kind) }

    func home(_ kind: AgentKind) -> URL { integration.home(of: kind) }

    func writtenFiles(_ kind: AgentKind) -> [String] {
        integration.writtenFiles(of: kind).map { UserHome.shown($0.path) }
    }

    func detect(_ kind: AgentKind) async {
        statuses[kind] = await integration.status(of: kind)
    }

    /// 检测时挑中的那个（`AgentStatus.executable`），开会话、起大脑、问模型都用它。
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

    var connectable: [AgentKind] {
        AgentKind.allCases.filter { kind in
            guard let status = statuses[kind] else { return false }
            return isWritable(kind) && status.isAvailable && status.files == .missing
        }
    }

    /// 返回没装上的与原因。
    func install(_ kinds: [AgentKind]) async -> [AgentKind: String] {
        var failures: [AgentKind: String] = [:]
        for kind in kinds {
            do { try await install(kind) } catch { failures[kind] = error.localizedDescription }
        }
        return failures
    }

    /// 没装上的原因记在 `jobs`（脚本输出的最后一句）。
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
            guard logins[kind] === process else { return }  // 被重来的那次换掉了
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

    /// 能开新会话的几家各起一个进程问，慢；只给写同步表 macAgents 的那一处（`MacAgentsRecorder`），界面读库。
    func probe() async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        await integration.probe(statuses)
    }

    /// 升级失败抛第一个错，状态仍反映磁盘上的旧版。
    func refresh() async throws {
        await redetect()
        var failure: (any Error)?
        for kind in AgentKind.allCases
        where isWritable(kind) && statuses[kind]?.files == .outdated && statuses[kind]?.isAvailable == true {
            do { try await install(kind) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// 新装或升级；已在运行的 Pi 会话经 `installed` 被请去核对，空闲时重新载入扩展。
    func install(_ kind: AgentKind) async throws {
        try await change(kind) { try await $0.install(kind) }
        installed(kind)
    }

    func uninstall(_ kind: AgentKind) async throws {
        let executable = statuses[kind]?.executable
        try await change(kind) { try await $0.uninstall(kind, executable: executable) }
        await uninstalled(kind)
    }

    private func change(_ kind: AgentKind, _ body: (AgentIntegration) async throws -> Void) async throws {
        do {
            try await body(integration)
        } catch {
            await detect(kind)
            throw error
        }
        await detect(kind)
    }
}

extension AppServices {
    /// 装完再问一遍这台各家能不能用、写进库（开会话、启用 Cue 读它）。
    func installAgent(_ kind: AgentKind) async throws {
        await agents.installAgent(kind)
        try await macAgents.record(redetecting: true)
    }
}

enum AgentJob: Equatable {
    case installing
    case loggingIn
    /// 上次没做成的原因（下次动手时清掉）
    case failed(String)
}
#endif
