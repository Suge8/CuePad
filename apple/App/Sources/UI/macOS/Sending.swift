#if os(macOS)
import CuePi
import CueStore
import CueText
import SwiftUI

extension Workspace {
    /// 开始：把叶子任务的第一句（`CueStore.opening`，与 Cue 的开工同一个函数）发给 Agent，交到哪只由 `CueStore.handOffPlan` 定：
    /// 接着用上一步的会话就发给它（在跑就打断这一轮）；要开新会话就开以任务命名的、开好后任务绑上它（项目没绑文件夹时执行的那台 Mac
    /// 先建工作区，`MacExecutor`）。正文发出后留在任务上。
    func handOff(_ leaf: Card) {
        start(leaf.id, fresh: false)
    }

    /// 给叶子开一个新会话，不接着用绑着的或上一步的会话（"绑定会话"里的"开新会话"；与 Cue 开工带 fresh 同一条规则，
    /// `CueStore.handOffPlan(fresh:)`）。
    func startFresh(_ leaf: Card) {
        start(leaf.id, fresh: true)
    }

    /// 没开成的原因提示一下，并留在任务气泡上（`launchFailures`）：一闪而过的提示条看漏了，任务就像什么都没发生地回到"开始"。
    private func start(_ leaf: UUID, fresh: Bool) {
        launchFailures[leaf] = nil
        attempt {
            do {
                try await self.handOff(leaf: leaf, fresh: fresh)
            } catch {
                self.launchFailures[leaf] = error.localizedDescription
                throw error
            }
        }
    }

    private func handOff(leaf: UUID, fresh: Bool) async throws {
        let store = services.store
        let plan = try await store.handOffPlan(leaf, host: services.hostID, fresh: fresh)
        let text = try await store.opening(of: leaf, plan.opensSession)
        switch plan.destination {
        case .session(let session, _, let host):
            send(text, to: AgentTarget(session: session, host: host), card: leaf)
        case .launch(let project, let host):
            // 会话名由任务定（`CueStore.requestLaunch`）；请求上显示的目标名同新会话的其他入口：任务没有标题时写项目名
            let projectName = try await services.store.project(project)?.shownName ?? ""
            let title = plan.name ?? projectName
            let agents = try await services.store.macAgents(on: host)
            guard let agent = agents.preferred(services.settings.lastAgent) else { throw SendError.noAgent(here: host == services.hostID, agents.whyNone) }
            _ = try await startSession(in: project, prompt: text.nonEmpty, title: title, on: host, card: leaf, agent: agent) { _ in }
        }
    }

    /// 发给 Agent（存储格式正文）：经 `speak` 写出就提示，不等送达（到哪了看任务那一行与会话页）。返回写库与上传的那个任务（测试等它）。
    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) -> Task<Void, Never> {
        let (listener, handed) = sendState.destination(to: target, card: card)
        return speak(stored, to: listener, saying: handed)
    }
}

extension Workspace {
    /// 在线 Pi 会话或项目目录绑定变了：重算会话归属的项目（`follow` 跟着）。
    func followSessionPlacement() async {
        for await _ in Observations({ self.sessionPlacement }) {
            do { try await sendState.refreshSessionProjects() } catch { fail(error) }
        }
    }

    private struct SessionPlacement: Equatable {
        var sessions: [String]
        var directories: [UUID: String]?
    }

    private var sessionPlacement: SessionPlacement {
        let pi = services.pi
        return SessionPlacement(sessions: pi.slots.map { "\($0.id) \($0.cwd.path)" }, directories: catalog?.directories)
    }
}
#endif
