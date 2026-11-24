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

nonisolated struct ThinkingMeter: Equatable {
    let levels: [ThinkingLevel]
    private(set) var current: ThinkingLevel?

    static let scale = ThinkingLevel.allCases.filter { $0 != .off }

    static func energy(_ level: ThinkingLevel) -> Double? {
        scale.firstIndex(of: level).map { Double($0) / Double(scale.count - 1) }
    }

    init?(levels: [ThinkingLevel], current: ThinkingLevel?) {
        guard !levels.isEmpty else { return nil }
        self.levels = levels
        self.current = current
    }

    var label: String { current?.label ?? String(localized: "默认") }
    var isMax: Bool { current != .off && current == ThinkingLevel.allCases.last(where: levels.contains) }

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
