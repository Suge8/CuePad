import CueStore
import SwiftUI

/// 会话页的模型菜单怎么写：按提供方（`PiProvider`）分组，组名有额度时带还剩多少；胶囊上的短名见 `PiModelName`。
nonisolated enum PiModelLabel {
    /// 分组标题：这家有订阅额度时写"Claude · 5 小时剩 86% · 本周剩 92%"（`QuotaMeter.menuTitle`），否则是提供方名。
    static func title(_ model: PiModelOption, quotas: [AccountQuota], at now: Date) -> String {
        if let quota = model.quota(in: quotas), let meter = QuotaMeter.all(quotas, at: now).first(where: { $0.id == quota.id }) { return meter.menuTitle.visible }
        if model.account?.source != nil {
            return Dotted(PiProvider(id: model.key.provider).name, String(localized: "账号额度见列表，路由账号未知")).visible
        }
        return model.account?.label(provider: model.key.provider) ?? PiProvider(id: model.key.provider).name
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

/// 思考强度条：格是一把固定的尺，除"关"以外的六档（最低到最高）各一格，当前档以下填满——同一档在哪个模型上都是同样几格（"低"总是两格），
/// 换了模型不换样子；模型不支持的档照样有格，指到那里取最近的支持档（`PiThinkingLevel.clamped(to:)`）。关着时格全空。
/// 拖动时按横向位置均分这把尺（模型能关时"关"在最左多占一份）。最高档的那道光给这个模型支持的最高一档。
nonisolated struct PiThinkingMeter: Equatable {
    /// 模型支持的档（空时没有这个条）。
    let levels: [PiThinkingLevel]
    private(set) var current: PiThinkingLevel?

    /// 那把尺：一格一档。
    static let scale = PiThinkingLevel.allCases.filter { $0 != .off }

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

    var filled: Int { current.flatMap { Self.scale.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
    var isOff: Bool { current == .off }
    /// 档名；Agent 没报此刻的强度时（如终端里的 Codex 用模型的缺省）是"默认"，照样能点能换。
    var label: String { current?.label ?? String(localized: "默认") }
    var isMax: Bool { current != .off && current == PiThinkingLevel.allCases.last(where: levels.contains) }

    func level(at fraction: Double) -> PiThinkingLevel {
        let stops = (levels.contains(.off) ? [.off] : []) + Self.scale
        let index = Int((min(max(fraction, 0), 0.999) * Double(stops.count)).rounded(.down))
        return stops[min(index, stops.count - 1)].clamped(to: levels)
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
        case .off: String(localized: "关")
        case .minimal: String(localized: "最低")
        case .low: String(localized: "低")
        case .medium: String(localized: "中")
        case .high: String(localized: "高")
        case .xhigh: String(localized: "很高")
        case .max: String(localized: "最高")
        }
    }
}
