import CueStore
import Foundation

/// 项目的"此刻"一行：每个项目只挑一件最该知道的事（iPad 侧栏、Mac 侧栏共用这一处规则；iPhone 书架不带会话，只剩任务与介绍）。
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
            return ProjectNow(source: .agent(agent.shown), text: sentence(agent.item, agent.shown))
        }
        return pick(task: task, intro: intro)
    }

    /// 没有会话可说时：进行中的任务，再是介绍。
    private static func pick(task: String?, intro: String?) -> ProjectNow? {
        if let task { return ProjectNow(source: .task, text: task) }
        return intro.map { ProjectNow(source: .intro, text: $0) }
    }

    /// iPhone 书架的"此刻"：书架不带会话（会话在 Agent 标签），只有最近开始的进行中任务与介绍；
    /// `listed` 是同一屏"正在推进"已列出的任务，任务那一档跳过它们、取下一条。
    static func shelf(_ projects: [Project], tasks: [UUID: [InProgress]], listed: Set<UUID>) -> [UUID: ProjectNow] {
        var result: [UUID: ProjectNow] = [:]
        for project in projects {
            result[project.id] = pick(task: tasks[project.id]?.first { !listed.contains($0.id) }?.title, intro: project.intro)
        }
        return result
    }

    /// 在线会话还没读到第一份（`LiveSessions.items` 为 nil）时：读到后一定有"此刻"的项目（有进行中任务或介绍）先留一行空白，
    /// 其余先不留；读到后空白原地淡入真的那句。不先写任务再被会话换掉（先错后对的闪变），名称也不挪位置。
    static func byProject(
        _ projects: [Project], sessions: [PiSessionListItem]?, tasks: [UUID: [InProgress]], shown: (PiSessionListItem) -> PiShown
    ) -> [UUID: ProjectNow] {
        let known = byProject(projects, sessions: sessions ?? [], tasks: tasks, shown: shown)
        return sessions == nil ? known.mapValues { _ in ProjectNow(source: .intro, text: "") } : known
    }

    /// 全部项目一次算完（界面在数据变化时算一次，行只拿结果）：会话按 `projectID` 归到项目。`sessions` 要传此刻有事的会话
    /// （`PiSessionQuery.current`：在线的，加上还有话发给它的已结束会话），只传在线的会漏掉发给已结束会话的话。
    static func byProject(
        _ projects: [Project], sessions: [PiSessionListItem], tasks: [UUID: [InProgress]], shown: (PiSessionListItem) -> PiShown
    ) -> [UUID: ProjectNow] {
        let intros = Dictionary(uniqueKeysWithValues: projects.compactMap { project in project.intro.map { (project.id, $0) } })
        return byProject(projects.map(\.id), sessions: sessions, tasks: tasks, intros: intros, shown: shown)
    }

    static func byProject(
        _ projects: [UUID], sessions: [PiSessionListItem], tasks: [UUID: [InProgress]], intros: [UUID: String],
        shown: (PiSessionListItem) -> PiShown
    ) -> [UUID: ProjectNow] {
        let byProject = Dictionary(grouping: sessions.filter { $0.state.projectID != nil }) { $0.state.projectID! }
        var result: [UUID: ProjectNow] = [:]
        for project in projects {
            let task = tasks[project]?.first?.title
            result[project] = pick(byProject[project] ?? [], shown: shown, task: task, intro: intros[project])
        }
        return result
    }

    /// 会话进得了"此刻"的档，就是会话列表的档（`PiShown.rank`，Agent 页同一套）：等你确认 → 出错与没能送达 → 在跑与话在路上
    /// → 需要 /reload → 有新回复；停着、已结束的不算。
    static func tier(_ shown: PiShown) -> Int? {
        switch shown.status {
        case .idle, .resting, .fresh, .ended, .interrupted, .unknown: nil
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
        case .delivery(.failed(let failure)): failure.text(sync: nil)
        case .delivery, .restart: nil
        default: PiProgress.line(of: item.state)
        }
    }
}
