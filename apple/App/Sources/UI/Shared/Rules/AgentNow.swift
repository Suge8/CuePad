import CueStore
import Foundation

/// 书架顶上的"Agent 此刻"一条（iPhone 与 iPad）：此刻有事的会话里挑最要紧的一档，主句只说谁、在怎样（一行放得下），
/// 次行说它在问什么、在做什么；同一档好几个时主句说个数、次行带过其余的。会话再多也只是这两行，变的是数字与叠放的头像。
/// 要紧的先后与项目的"此刻"、Agent 页列表同一档（`ProjectNow.tier` 即 `PiShown.rank`）：等你确认 → 出错与没能送达
/// → 在干活与话在路上 → 要重载 → 有新回复；停着、已结束的不算，全都停着就没有这一条。
nonisolated struct AgentNow: Equatable, Sendable {
    /// 主句："deploy 在等你确认"；同一档有好几个时说个数："3 个 Agent 在干活"。
    let headline: String
    /// 次行：只有一个时是它在问什么、在做什么（说不出时同下）；好几个时带过其余各档（"还有 1 个出错 · 2 个在干活"，最多两档），
    /// 没有其余的时候是它们的名字；只有一个又都说不出时是它在哪。
    let detail: Dotted?
    /// 最要紧那一档的状态：等你确认、出错时整条按它的颜色强调（赭黄、胭脂），否则中性。
    let lead: PiShown
    /// 叠放的头像：按要紧的先后取前几个。
    let faces: [PiSessionListItem]
    /// 头像以外还有几个（写成"+N"）。
    let more: Int

    static let faceLimit = 3
    static let restLimit = 2

    var needsYou: Bool { lead.needsYou }

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
        let restLine: Dotted? = rest.first.map { Dotted(["还有 " + $0] + rest.dropFirst()) }
        let detail: Dotted? = if lead.count > 1 {
            restLine ?? Dotted(lead.map(\.item.state.title).joined(separator: "、"))
        } else {
            ProjectNow.gist(top.item, top.shown).map { Dotted($0) } ?? restLine
                ?? PiPlace.name(of: top.item.state, project: top.item.project).map { Dotted("在 \($0)") }
        }
        return AgentNow(
            headline: lead.count > 1 ? "\(lead.count) 个 Agent \(verb(tier: top.tier))" : headline(top.item, top.shown),
            detail: detail, lead: top.shown,
            faces: ranked.prefix(faceLimit).map(\.item), more: max(0, ranked.count - faceLimit))
    }

    /// 只有一个时的主句：谁、在怎样。
    private static func headline(_ item: PiSessionListItem, _ shown: PiShown) -> String {
        let name = item.state.title
        return switch shown.status {
        case .asking: "\(name) 在等你确认"
        case .cueAsking: "\(name) 在等 \(shown.cue ?? "") 回答"
        case .failed: "\(name) 出错了"
        case .delivery(.failed): "没能送到 \(name)"
        case .delivery(.waking): "正在唤醒 \(name)"
        case .delivery: "正在发给 \(name)"
        case .working: "\(name) 在干活"
        case .unread: "\(name) 回复了"
        case .restart: "\(name) 要在终端里重载"
        case .interrupted: "\(name) 被打断了"
        case .idle, .resting, .fresh, .ended, .unknown: name
        }
    }

    /// 好几个时主句的说法（"3 个 Agent 在干活"）。
    private static func verb(tier: Int) -> String {
        switch tier {
        case 0: "在等你确认"
        case 1: "出错了"
        case 2: "在干活"
        case 3: "要重载"
        default: "有新回复"
        }
    }

    /// 次行里其余各档的说法（"1 个出错"）。
    private static func phrase(tier: Int) -> String {
        switch tier {
        case 0: "在等你"
        case 1: "出错"
        case 2: "在干活"
        case 3: "要重载"
        default: "有新回复"
        }
    }
}
