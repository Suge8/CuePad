import CueStore
import Foundation

/// 项目的"此刻"一行：每个项目只挑一件最该知道的事（书架大卡与行、iPad 侧栏、Mac 侧栏共用这一处规则）。
/// 按优先取第一个：Agent 等你确认（它在问什么）→ 出错与没能送达（原因；没能送达看过那个会话就不算，同会话行）→ Agent 在跑与话在路上（在做什么）→ 需要 /reload
/// → 有新回复（回复第一句）→ 最近开始的进行中任务 → 项目介绍（会话之间的先后就是会话列表的档 `PiShown.rank`）；都没有就是 nil，行照样留着高度。状态标与颜色都按 `PiShown`：只有要你动手的带色。
nonisolated struct ProjectNow: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case agent(PiShown)
        case task
        case intro
    }

    let source: Source
    let text: String
    /// Agent 的事是哪个会话（会话名）；项目行不写它，书架的 Agent 总览写不在项目里的那件时带上。
    var session: String?

    /// 一条进行中的任务（`TaskBoard.leading` 按项目给出，最近开始的在前）。
    struct InProgress: Hashable, Sendable {
        let id: UUID
        let title: String
    }

    /// Agent 的事才有状态（书架、侧栏的状态标与项目长按菜单的标题读它）。
    var shown: PiShown? {
        if case .agent(let shown) = source { shown } else { nil }
    }

    /// 要你动手（等你确认、出错）：只有这时状态标带色。
    var needsYou: Bool { shown?.needsYou ?? false }

    /// 一个项目的在线会话（`sessions`）、最近开始的进行中任务标题（`task`）与介绍里挑一件。
    static func pick(
        _ sessions: [PiSessionListItem], shown: (PiSessionListItem) -> PiShown, task: String?, intro: String?
    ) -> ProjectNow? {
        let agent = sessions
            .map { (item: $0, shown: shown($0)) }
            .compactMap { pair in tier(pair.shown).map { (tier: $0, item: pair.item, shown: pair.shown) } }
            .min { $0.tier < $1.tier }
        if let agent {
            return ProjectNow(source: .agent(agent.shown), text: sentence(agent.item, agent.shown), session: agent.item.state.title)
        }
        if let task { return ProjectNow(source: .task, text: task) }
        if let intro { return ProjectNow(source: .intro, text: intro) }
        return nil
    }

    /// 全部项目一次算完（界面在数据变化时算一次，行只拿结果）：会话按 `projectID` 归到项目。`sessions` 要传此刻有事的会话
    /// （`PiSessionQuery.current`：在线的，加上还有话发给它的已结束会话），只传在线的会漏掉发给已结束会话的话。
    /// `listed` 是同一屏已列出的任务（书架的"正在推进"），任务那一档跳过它们、取下一条；没有这种清单的地方不传。
    static func byProject(
        _ projects: [Project], sessions: [PiSessionListItem], tasks: [UUID: [InProgress]], listed: Set<UUID> = [],
        shown: (PiSessionListItem) -> PiShown
    ) -> [UUID: ProjectNow] {
        let intros = Dictionary(uniqueKeysWithValues: projects.compactMap { project in project.intro.map { (project.id, $0) } })
        return byProject(projects.map(\.id), sessions: sessions, tasks: tasks, intros: intros, listed: listed, shown: shown)
    }

    static func byProject(
        _ projects: [UUID], sessions: [PiSessionListItem], tasks: [UUID: [InProgress]], intros: [UUID: String],
        listed: Set<UUID> = [], shown: (PiSessionListItem) -> PiShown
    ) -> [UUID: ProjectNow] {
        let byProject = Dictionary(grouping: sessions.filter { $0.state.projectID != nil }) { $0.state.projectID! }
        var result: [UUID: ProjectNow] = [:]
        for project in projects {
            let task = tasks[project]?.first { !listed.contains($0.id) }?.title
            result[project] = pick(byProject[project] ?? [], shown: shown, task: task, intro: intros[project])
        }
        return result
    }

    /// 会话进得了"此刻"的档，就是会话列表的档（`PiShown.rank`，Agent 页同一套）：等你确认 → 出错与没能送达 → 在跑与话在路上
    /// → 需要 /reload → 有新回复；停着、已结束的不算。书架的 Agent 此刻（`AgentNow`）按同一档排。
    static func tier(_ shown: PiShown) -> Int? {
        switch shown.status {
        case .idle, .fresh, .ended, .unknown: nil
        default: shown.rank
        }
    }

    private static func sentence(_ item: PiSessionListItem, _ shown: PiShown) -> String {
        switch shown.status {
        case .restart: "要在终端里重载"
        case .delivery(.failed): gist(item, shown) ?? shown.presence
        case .delivery: shown.presence
        default: gist(item, shown) ?? shown.presence
        }
    }

    /// 这件事的那一句：在问什么、出错或没送到的原因、在做什么、回复的第一句；说不出时是 nil。
    static func gist(_ item: PiSessionListItem, _ shown: PiShown) -> String? {
        switch shown.status {
        case .delivery(.failed): item.delivery?.failure
        case .delivery, .restart: nil
        default: PiProgress.line(of: item.state)
        }
    }
}
