#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation
import SystemConfiguration

/// 这台 Mac 上的 Agent 能不能用、各家的模型（同步表 macAgents）只经这里写，内容变了才写（同步层马上传）；各处读库，这里不留结果。
/// 一次问完再问下一次，后问的不会被先问的覆盖。不合并请求：触发很少，问一次最慢约 2 秒。
/// 系统唤醒时先重新检测各家：睡着时可能装、换、卸了 Agent，登录或换了模型配置。Cue 启用前经 `record` 等这一次写完再按库里的判断，刚启动还没问完时启用也不会读到旧的或空的。
/// 接入面板打开、回到 App、装完或登录完一家时由 `Workspace.recheckAgents` 触发：登录不改检测出的状态，不重问就看不到。
/// 一次问用的状态记着（`probed`）：这次自己重新检测引起的状态变化不再触发一次。
@MainActor
final class MacAgentsRecorder {
    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let host: String
    private let agents: AgentIntegrations
    private var latest: Task<MacAgents, any Error>?
    private var probed: [AgentKind: AgentStatus]?

    init(store: CueStore, sync: (any SyncControlling)?, host: String, agents: AgentIntegrations) {
        self.store = store
        self.sync = sync
        self.host = host
        self.agents = agents
    }

    /// `redetecting`：问之前先重新检测各家（只检测，不升级、不写文件）；还没检测全的也先检测。
    @discardableResult
    func record(redetecting: Bool = false) async throws -> MacAgents {
        let before = latest
        let round = Task { [self] in
            _ = await before?.result
            if redetecting || !agents.detected { await agents.redetect() }
            probed = agents.statuses
            let found = await agents.probe()
            let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
            try await store.recordMacAgents(host: host, name: name, found.agents, problems: found.problems)
            return try await store.macAgents(on: host)
        }
        latest = round
        return try await round.value
    }

    func keep(notifications center: NotificationCenter) async throws {
        let statuses = Observations { [agents] in agents.statuses }
        let wakes = center.notifications(named: NSWorkspace.didWakeNotification)
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                for await _ in wakes { try await self.record(redetecting: true) }
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
