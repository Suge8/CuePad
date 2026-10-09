import CueStore
import Foundation

/// 书架顶上的"Agent 此刻"一条（iPhone 与 iPad）：此刻有事的会话里挑最要紧的一档，用一句人话说（谁、在怎样），
/// 次行补一句其余的；会话再多也只是这两行，变的是数字与叠放的头像。要紧的先后与项目的"此刻"同一档（`ProjectNow.tier`）：
/// 等你确认 → 出错与没能送达 → 在干活与话在路上 → 有新回复 → 要 /reload；停着、已结束的不算，全都停着就没有这一条。
nonisolated struct AgentNow: Equatable, Sendable {
    /// 主句："deploy 在问：部署到生产吗？"；同一档有好几个时说个数："3 个 Agent 在干活"。
    let headline: String
    /// 次行：其余各档一句带过（"还有 1 个出错 · 2 个在干活"，最多两档）；没有其余的时候，一个是它在哪、好几个是它们的名字。
    let detail: String?
    /// 最要紧的是等你确认或出错：整条带赭黄强调，否则中性。
    let needsYou: Bool
    /// 叠放的头像：按要紧的先后取前几个。
    let faces: [PiSessionListItem]
    /// 头像以外还有几个（写成"+N"）。
    let more: Int

    static let faceLimit = 3
    static let restLimit = 2

    static func of(_ sessions: [PiSessionListItem], shown: (PiSessionListItem) -> PiShown) -> AgentNow? {
        let ranked = sessions.compactMap { item -> (tier: Int, item: PiSessionListItem, shown: PiShown)? in
            let shown = shown(item)
            return ProjectNow.tier(shown).map { ($0, item, shown) }
        }
        .enumerated().sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }.map(\.element)
        guard let top = ranked.first else { return nil }
        let lead = ranked.filter { $0.tier == top.tier }
        let others = Dictionary(grouping: ranked.dropFirst(lead.count), by: \.tier).sorted { $0.key < $1.key }
        // 次行最多带过两档（一行放得下）：再往后的不如头像与 Agent 页里看
        let rest = others.prefix(Self.restLimit).map { "\($0.value.count) 个\(phrase(tier: $0.key))" }
        let detail: String? = if !rest.isEmpty {
            "还有 " + rest.joined(separator: " · ")
        } else if lead.count > 1 {
            lead.map(\.item.state.title).joined(separator: "、")
        } else {
            PiPlace.name(of: top.item.state, project: top.item.project).map { "在 \($0)" }
        }
        return AgentNow(
            headline: lead.count > 1 ? "\(lead.count) 个 Agent \(verb(tier: top.tier))" : headline(top.item, top.shown),
            detail: detail, needsYou: top.tier <= 1,
            faces: ranked.prefix(faceLimit).map(\.item), more: max(0, ranked.count - faceLimit))
    }

    /// 只有一个时的主句。
    private static func headline(_ item: PiSessionListItem, _ shown: PiShown) -> String {
        let name = item.state.title, gist = ProjectNow.gist(item, shown)
        func said(_ lead: String) -> String { gist.map { "\(lead)：\($0)" } ?? lead }
        return switch shown.status {
        case .asking: gist.map { "\(name) 在问：\($0)" } ?? "\(name) 在等你确认"
        case .failed: said("\(name) 出错了")
        case .delivery(.failed): said("没能送到 \(name)")
        case .delivery(.waking): "正在唤醒 \(name)"
        case .delivery: "正在发给 \(name)"
        // 还没有具体动作时那一句本身就是"正在处理：…"，不再套一层"在干活"
        case .working: gist.flatMap { $0.hasPrefix("正在") ? "\(name) \($0)" : nil } ?? said("\(name) 在干活")
        case .unread: said("\(name) 回复了")
        case .restart: "\(name) 要在终端里 /reload"
        case .idle, .fresh, .ended, .unknown: name
        }
    }

    /// 好几个时主句的说法（"3 个 Agent 在干活"）。
    private static func verb(tier: Int) -> String {
        switch tier {
        case 0: "在等你确认"
        case 1: "出错了"
        case 2: "在干活"
        case 3: "有新回复"
        default: "要 /reload"
        }
    }

    /// 次行里其余各档的说法（"1 个出错"）。
    private static func phrase(tier: Int) -> String {
        switch tier {
        case 0: "在等你"
        case 1: "出错"
        case 2: "在干活"
        case 3: "有新回复"
        default: "要 /reload"
        }
    }
}
