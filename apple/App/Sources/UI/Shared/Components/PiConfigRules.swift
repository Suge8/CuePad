import CueStore
import SwiftUI



/// 会话页的模型菜单怎么写：按提供方（`PiProvider`）分组，组名有额度时带还剩多少；胶囊上的短名见 `PiModelName`。
nonisolated enum PiModelLabel {
    /// 分组标题：这家有订阅额度时写"Claude · 5 小时剩 86% · 本周剩 92%"（`QuotaMeter.menuTitle`），否则是提供方名。
    static func title(_ provider: PiProvider, quotas: [AccountQuota], at now: Date) -> String {
        quotas.first { $0.provider == provider.id }.map { QuotaMeter($0, at: now).menuTitle.visible } ?? provider.name
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
    private(set) var current: PiThinkingLevel?

    /// 模型不报档位时没有这个条：拖动换算档位要从档位里取。
    init?(levels: [PiThinkingLevel], current: PiThinkingLevel?) {
        guard !levels.isEmpty else { return nil }
        self.levels = levels
        self.current = current
    }

    /// 同一组档位、指着 `level`（按着拖动时先在条上预览）。
    func pointing(at level: PiThinkingLevel) -> PiThinkingMeter {
        var meter = self
        meter.current = level
        return meter
    }

    var bars: [PiThinkingLevel] { levels.filter { $0 != .off } }
    var filled: Int { current.flatMap { bars.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
    var isOff: Bool { current == .off }
    /// 档名；Agent 没报此刻的强度时（如终端里的 Codex 用模型的缺省）是"默认"，照样能点能换。
    var label: String { current?.label ?? "默认" }
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
