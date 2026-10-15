#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation

/// 这台 Mac 上的 Agent 能不能用、各家的模型（同步表 macAgents）只经这里写：按检测出的接入状态问（`AgentIntegrations.probe`），
/// 内容变了才写，写了立即上传；各处读库，这里不留结果。
/// 一次问完再问下一次，后问的不会被先问的覆盖。不合并请求：触发很少（状态变了、醒来、启用），问一次最慢约 2 秒。
/// 什么时候问：各家接入状态都检测出来、状态变了（`keep`），系统唤醒时（先重新检测各家：睡着时可能装、换、卸了 Agent，登录或换了模型配置），
/// 以及 Cue 启用前（`record`：等这一次写完再按库里的判断，刚启动还没问完时启用也不会读到旧的或空的）。
/// 一次问用的状态记着（`probed`）：这次自己重新检测引起的状态变化不再触发一次。
@MainActor
final class MacAgentsRecorder {
    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let host: String
    private let agents: AgentIntegrations
    /// 最近排上的那一次
    private var latest: Task<MacAgents, any Error>?
    /// 最近一次问用的接入状态
    private var probed: [AgentKind: AgentStatus]?

    init(store: CueStore, sync: (any SyncControlling)?, host: String, agents: AgentIntegrations) {
        self.store = store
        self.sync = sync
        self.host = host
        self.agents = agents
    }

    /// 重新问一次并写下，返回写完后库里这台 Mac 的那条。`redetecting`：问之前先重新检测各家（只检测，不升级、不写文件）；
    /// 还没检测全的也先检测。
    @discardableResult
    func record(redetecting: Bool = false) async throws -> MacAgents {
        let before = latest
        let round = Task { [self] in
            _ = await before?.result
            if redetecting || agents.statuses.count < AgentKind.allCases.count { await agents.redetect() }
            probed = agents.statuses
            let found = await agents.probe()
            if let id = try await store.recordMacAgents(host: host, found.agents, problems: found.problems) { await sync?.upload(id) }
            return try await store.macAgents(on: host)
        }
        latest = round
        return try await round.value
    }

    /// 跟着接入状态与系统唤醒问，直到任务取消。
    func keep(notifications center: NotificationCenter) async throws {
        let statuses = Observations { [agents] in agents.statuses }
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) { try await self.record(redetecting: true) }
            }
            group.addTask {
                for await now in statuses where now.count == AgentKind.allCases.count {
                    if await self.probed != now { try await self.record() }
                }
            }
        }
    }
}
#endif
