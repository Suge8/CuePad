import CueStore
import SwiftUI

nonisolated enum ModelLabel {
    static func title(_ model: ModelOption, quotas: [AccountQuota], at now: Date) -> String {
        if let quota = model.quota(in: quotas), let meter = QuotaMeter.all(quotas, at: now).first(where: { $0.id == quota.id }) { return meter.menuTitle.visible }
        if model.account?.source != nil {
            return Dotted(Provider(id: model.key.provider).name, String(localized: "账号额度见列表，路由账号未知")).visible
        }
        return model.account?.label(provider: model.key.provider) ?? Provider(id: model.key.provider).name
    }

    static func groups(_ models: [ModelOption]) -> [(provider: Provider, models: [ModelOption])] {
        var order: [String] = []
        var byProvider: [String: [ModelOption]] = [:]
        for model in models {
            if byProvider[model.key.provider] == nil { order.append(model.key.provider) }
            byProvider[model.key.provider, default: []].append(model)
        }
        return order.map { (Provider(id: $0), byProvider[$0] ?? []) }
    }
}

/// 思考强度条：格是一把固定的尺，除"关"以外的六档（最低到最高）各一格，当前档以下填满——同一档在哪个模型上都是同样几格（"低"总是两格），
/// 换了模型不换样子；模型不支持的档照样有格，指到那里取最近的支持档（`ThinkingLevel.clamped(to:)`）。关着时格全空。
nonisolated struct ThinkingMeter: Equatable {
    let levels: [ThinkingLevel]
    private(set) var current: ThinkingLevel?

    static let scale = ThinkingLevel.allCases.filter { $0 != .off }

    init?(levels: [ThinkingLevel], current: ThinkingLevel?) {
        guard !levels.isEmpty else { return nil }
        self.levels = levels
        self.current = current
    }

    func pointing(at level: ThinkingLevel) -> ThinkingMeter {
        var meter = self
        meter.current = level
        return meter
    }

    var filled: Int { current.flatMap { Self.scale.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
    var isOff: Bool { current == .off }
    /// 档名；Agent 没报此刻的强度时（用模型的缺省）是"默认"，照样能点能换。
    var label: String { current?.label ?? String(localized: "默认") }
    var isMax: Bool { current != .off && current == ThinkingLevel.allCases.last(where: levels.contains) }

    func level(at fraction: Double) -> ThinkingLevel {
        let stops = (levels.contains(.off) ? [.off] : []) + Self.scale
        let index = Int((min(max(fraction, 0), 0.999) * Double(stops.count)).rounded(.down))
        return stops[min(index, stops.count - 1)].clamped(to: levels)
    }

    func step(_ delta: Int) -> ThinkingLevel? {
        guard let current, let index = levels.firstIndex(of: current) else { return levels.first }
        let next = index + delta
        return levels.indices.contains(next) ? levels[next] : nil
    }
}

extension ThinkingLevel {
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
