#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation
import SystemConfiguration

@MainActor
final class MacAgentsRecorder {
    private let store: CueStore
    private let host: String
    private let agents: AgentIntegrations
    private var latest: Task<MacAgents, any Error>?
    private var probed: [AgentKind: AgentStatus]?

    init(store: CueStore, host: String, agents: AgentIntegrations) {
        self.store = store
        self.host = host
        self.agents = agents
    }

    @discardableResult
    func record(redetecting: Bool = false) async throws -> MacAgents {
        let before = latest
        let round = Task { [self] in
            _ = await before?.result
            if redetecting || !agents.detected { await agents.redetect() }
            probed = agents.statuses
            let found = await agents.integration.probe(agents.statuses)
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
