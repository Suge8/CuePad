import CueStore
import SwiftUI



/// 会话页的模型菜单怎么写：按提供方（`PiProvider`）分组，组名有额度时带用量；胶囊上的短名见 `PiModelName`。
nonisolated enum PiModelLabel {
    /// 分组标题：这家有订阅额度时写"Claude · 5 小时 14% · 本周 8%"（`QuotaMeter.menuTitle`），否则是提供方名。
    static func title(_ provider: PiProvider, quotas: [AccountQuota], at now: Date) -> String {
        quotas.first { $0.provider == provider.id }.map { QuotaMeter($0, at: now).menuTitle.visible } ?? provider.name
    }

    /// 胶囊最宽是这一排宽度的一半，至少 96（短名放得下）、至多 240（iPad、Mac 宽屏不至于拉得过长）。
    static func capsuleWidth(available: CGFloat) -> CGFloat {
        min(max(available * 0.5, 96), 240)
    }

    /// 菜单里的分组：提供方按第一次出现的顺序。
    static func groups(_ models: [PiModelOption]) -> [(provider: PiProvider, models: [PiModelOption])] {
        var order: [String] = []
        var byProvider: [String: [PiModelOption]] = [:]
        for model in models {
            if byProvider[model.key.provider] == nil { order.append(model.key.provider) }
            byProvider[model.key.provider, default: []].append(model)
        }
        return order.map { (PiProvider(id: $0), byProvider[$0] ?? []) }
    }
}


/// 思考强度条：格是当前模型支持的档位里除"关"以外的几档，当前档以下填满；关着时格全空。
/// 拖动时按横向位置均分所有档（含"关"，在最左）。
nonisolated struct PiThinkingMeter: Equatable {
    let levels: [PiThinkingLevel]
    let current: PiThinkingLevel?

    var bars: [PiThinkingLevel] { levels.filter { $0 != .off } }
    var filled: Int { current.flatMap { bars.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
    var isOff: Bool { current == .off }
    /// 填到最高一档。
    var isMax: Bool { !bars.isEmpty && filled == bars.count }

    func level(at fraction: Double) -> PiThinkingLevel {
        let index = Int((min(max(fraction, 0), 0.999) * Double(levels.count)).rounded(.down))
        return levels[min(index, levels.count - 1)]
    }

    /// 读屏的上一档、下一档。
    func step(_ delta: Int) -> PiThinkingLevel? {
        guard let current, let index = levels.firstIndex(of: current) else { return levels.first }
        let next = index + delta
        return levels.indices.contains(next) ? levels[next] : nil
    }
}


extension PiThinkingLevel {
    /// 思考强度给人看的名字。
    nonisolated var label: String {
        switch self {
        case .off: "关"
        case .minimal: "最低"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "很高"
        case .max: "最高"
        }
    }
}
