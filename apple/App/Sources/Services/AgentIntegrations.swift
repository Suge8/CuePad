#if os(macOS)
import CuePi
import CueStore
import Foundation
import Observation

/// CuePad 接入各个 Agent 的状态与开关（`AgentIntegration` 之上唯一的一份，设置、首次接入与侧栏都读它）。
/// 装只在用户点了之后（首次接入面板、设置的开关、侧栏的"接入 Pi"）；装过的在 `refresh()` 发现与这个版本的 App 要写的不同时
/// （App 更新了，或 App 被移动后技能里的 cuepad 路径变了）静默升级，不再询问——App 启动时就会 `refresh()`。
/// 隔离运行（开发构建）只写配置目录经环境变量换走了的那几家（`AgentIntegration.isWritable`），其余只检测。
@Observable
final class AgentIntegrations {
    /// 第一次检测完成前为空
    private(set) var statuses: [AgentKind: AgentStatus] = [:]
    @ObservationIgnored private let integration: AgentIntegration
    /// 移除成功之后（关掉开关）：收起 CuePad 为它起的东西（如 CuePad 拉起的 OpenCode 服务）
    @ObservationIgnored var uninstalled: (AgentKind) async -> Void = { _ in }
    /// 这台 Mac 上能用的 Agent 与各家的模型（`AgentIntegration.available`，各起一个进程问，慢）：只交给写同步表 macAgents 的那一处，
    /// 界面读库。测试换成给定的。
    @ObservationIgnored var probe: @Sendable () async -> [MacAgent]

    init(_ integration: AgentIntegration) {
        self.integration = integration
        probe = { await integration.available() }
    }

    func status(_ kind: AgentKind) -> AgentStatus? { statuses[kind] }

    func isWritable(_ kind: AgentKind) -> Bool { integration.isWritable(kind) }

    func home(_ kind: AgentKind) -> URL { integration.home(of: kind) }

    /// CuePad 会写的文件（`~/.claude/skills/cuepad/SKILL.md` 这样的写法），给界面说明。
    func writtenFiles(_ kind: AgentKind) -> [String] {
        integration.writtenFiles(of: kind).map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    /// 重新检测一个 Agent（设置与接入面板里它那一行出现时：用户可能刚装了它）。不写任何文件。
    func detect(_ kind: AgentKind) async {
        statuses[kind] = await integration.status(of: kind)
    }

    /// 启动时：检测全部 Agent，装过而内容不同的升级到这个版本。升级失败抛第一个错，状态仍反映磁盘上的旧版。
    func refresh() async throws {
        await withDiscardingTaskGroup { group in
            for kind in AgentKind.allCases { group.addTask { await self.detect(kind) } }
        }
        var failure: (any Error)?
        for kind in AgentKind.allCases
        where isWritable(kind) && statuses[kind]?.files == .outdated && statuses[kind]?.isAvailable == true {
            do { try await install(kind) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// 新装或升级；已在运行的 Pi 会话空闲时自己重新载入扩展（更早的旧扩展要在终端里 /reload）。
    func install(_ kind: AgentKind) async throws {
        try await change(kind) { try await $0.install(kind) }
    }

    /// 删掉 CuePad 写给它的全部文件。
    func uninstall(_ kind: AgentKind) async throws {
        try await change(kind) { try await $0.uninstall(kind) }
        await uninstalled(kind)
    }

    /// 改完（成功或失败）都重读这一个的状态。
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
#endif
