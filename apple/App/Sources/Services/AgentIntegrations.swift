#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation
import Observation

/// CuePad 接入各个 Agent 的状态与开关（`AgentIntegration` 之上唯一的一份，设置、接入面板与会话页都读它）。
/// 装只在用户点了之后（接入面板的主按钮、设置的开关）；装过的在 `refresh()` 发现与这个版本的 App 要写的不同时
/// （App 更新了，或 App 被移动后技能里的 cuepad 路径变了）静默升级，不再询问——App 启动时就会 `refresh()`。
/// 隔离运行（开发构建）只写配置目录经环境变量换走了的那几家（`AgentIntegration.isWritable`），其余只检测。
@Observable
final class AgentIntegrations {
    private(set) var statuses: [AgentKind: AgentStatus] = [:]
    /// 在后台装、登录的那几家（接入面板的"安装""登录"）与没做成的原因；做成了就没有这一项，之后看检测与探测。
    private(set) var jobs: [AgentKind: AgentJob] = [:]
    /// 在等你在浏览器里登录完的进程：再点一次登录先结束旧的（Codex 的登录占着固定端口）。
    @ObservationIgnored private var logins: [AgentKind: ChildProcess] = [:]

    /// 每一家都检测过了（之前的"有哪些"还说不准，界面写检测中）。
    var detected: Bool { statuses.count == AgentKind.allCases.count }
    @ObservationIgnored private let integration: AgentIntegration
    /// 移除成功之后（关掉开关）：收起 CuePad 为它起的东西（如 CuePad 拉起的 OpenCode 服务）
    @ObservationIgnored var uninstalled: (AgentKind) async -> Void = { _ in }

    init(_ integration: AgentIntegration) {
        self.integration = integration
    }

    func status(_ kind: AgentKind) -> AgentStatus? { statuses[kind] }

    func isWritable(_ kind: AgentKind) -> Bool { integration.isWritable(kind) }

    func home(_ kind: AgentKind) -> URL { integration.home(of: kind) }

    /// CuePad 会写的文件（`~/.claude/skills/cuepad/SKILL.md` 这样的写法），给界面说明。
    func writtenFiles(_ kind: AgentKind) -> [String] {
        integration.writtenFiles(of: kind).map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    /// 重新检测一个 Agent（设置里它那一行出现时：用户可能刚装了它）。不写任何文件。
    func detect(_ kind: AgentKind) async {
        statuses[kind] = await integration.status(of: kind)
    }

    /// 这家的可执行文件：检测时挑中的那个（`AgentStatus.executable`），开会话、起大脑、问模型都用它；还没检测过先检测。
    func executable(_ kind: AgentKind) async -> URL? {
        if statuses[kind] == nil { await detect(kind) }
        return statuses[kind]?.executable
    }

    /// 重新检测全部 Agent，测完一次换上（状态只变一次）。不写任何文件。
    func redetect() async {
        let integration = integration
        statuses = await withTaskGroup(of: (AgentKind, AgentStatus).self) { group in
            for kind in AgentKind.allCases { group.addTask { (kind, await integration.status(of: kind)) } }
            var found: [AgentKind: AgentStatus] = [:]
            for await (kind, status) in group { found[kind] = status }
            return found
        }
    }

    /// 接入面板列出的几家：这台 Mac 上检测到、CuePad 能写、还没接入的（按 `AgentKind` 的顺序）。
    var connectable: [AgentKind] {
        AgentKind.allCases.filter { kind in
            guard let status = statuses[kind] else { return false }
            return isWritable(kind) && status.isAvailable && status.files == .missing
        }
    }

    /// 一键接入这几家（接入面板的主按钮，同设置里逐个打开开关）：逐家装，返回没装上的与原因。
    func install(_ kinds: [AgentKind]) async -> [AgentKind: String] {
        var failures: [AgentKind: String] = [:]
        for kind in kinds {
            do { try await install(kind) } catch { failures[kind] = error.localizedDescription }
        }
        return failures
    }

    /// 在后台跑这家的官方安装脚本（`AgentKind.installCommand`），装完重新检测它；没装上的原因记在 `jobs`（脚本输出的最后一句）。
    func installAgent(_ kind: AgentKind) async {
        jobs[kind] = .installing
        let result = await integration.runInstaller(kind, statuses[kind]?.presence ?? .notFound)
        await detect(kind)
        jobs[kind] = switch result {
        case nil: .failed("安装超时")
        case let (status, output)? where status != 0: .failed(Self.lastLine(output) ?? "安装没成功")
        case _ where statuses[kind]?.isAvailable != true: .failed("装好了，但找不到 \(kind.command)")
        default: nil
        }
    }

    /// 命令行登录（`AgentKind.loginArguments`，会打开浏览器），等它结束；再点一次就结束旧的、等它退出（放开 Codex 的固定端口）再重来。
    /// 没登录成的记在 `jobs`。
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
            jobs[kind] = status == 0 ? nil : .failed("没登录成功")
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

    /// 输出里最后一句话（去掉终端的颜色控制符）：失败时给人看的原因。
    private static func lastLine(_ output: String) -> String? {
        output.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// 各家能不能用与模型（`AgentIntegration.probe`）：按此刻检测出的状态。能开新会话的几家各起一个进程问，慢；
    /// 只给写同步表 macAgents 的那一处（`MacAgentsRecorder`），界面读库。
    func probe() async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        await integration.probe(statuses)
    }

    /// 启动时：检测全部 Agent，装过而内容不同的升级到这个版本。升级失败抛第一个错，状态仍反映磁盘上的旧版。
    func refresh() async throws {
        await redetect()
        var failure: (any Error)?
        for kind in AgentKind.allCases
        where isWritable(kind) && statuses[kind]?.files == .outdated && statuses[kind]?.isAvailable == true {
            do { try await install(kind) } catch { failure = failure ?? error }
        }
        do { try await integration.retireLegacyPiExtension() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// 新装或升级；已在运行的 Pi 会话空闲时自己重新载入扩展。
    func install(_ kind: AgentKind) async throws {
        try await change(kind) { try await $0.install(kind) }
    }

    /// v37 单文件扩展到 v38 目录扩展的过渡：Pi 会话上线、下线（含换上新扩展时的重连）时复查旧扩展的存根还要不要留（`AgentIntegration.retireLegacyPiExtension`）。
    /// 用户的 Mac 都装过一次 v38 起的 CuePad 并启动过（启动检查把旧扩展换掉）后，连同 Kit 里的存根与 `legacyPiExtensionInUse` 一起删。
    func retireLegacyPiExtension(following changes: AsyncStream<PiSessionChange>) async throws {
        for await change in changes {
            if case .appeared = change { try await integration.retireLegacyPiExtension() }
            if case .ended = change { try await integration.retireLegacyPiExtension() }
        }
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

/// 在后台装、登录一家的进度（`AgentIntegrations.jobs`）。
enum AgentJob: Equatable {
    case installing
    case loggingIn
    /// 上次没做成的原因（下次动手时清掉）
    case failed(String)
}
#endif
