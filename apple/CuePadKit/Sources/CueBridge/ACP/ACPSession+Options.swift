#if os(macOS)
import CueStore
import Foundation

/// 模型与思考强度两项读成 CuePad 的写法，换用 `session/set_config_option`；强度的值照 `ThinkingLevel` 的写法对上，夹到这一项有的档位。
extension ACPSession {
    func option(_ category: String) -> JSONValue? { options.first { $0["category"]?.string == category } }

    private func values(_ option: JSONValue?) -> [JSONValue] {
        (option?["options"]?.array ?? []).flatMap { $0["options"]?.array ?? [$0] }
    }

    var currentModel: String? { option("model")?["currentValue"]?.string }
    var currentLevel: ThinkingLevel? { option("thought_level")?["currentValue"]?.string.flatMap(ThinkingLevel.init(rawValue:)) }
    var levels: [ThinkingLevel] { values(option("thought_level")).compactMap { $0["value"]?.string.flatMap(ThinkingLevel.init(rawValue:)) } }

    var models: [ModelOption] {
        values(option("model")).compactMap { value in
            value["value"]?.string.map { ModelOption(key: key($0), name: value["name"]?.string ?? $0, thinkingLevels: levels) }
        }
    }

    /// 在用的模型：按完整的模型键对（模型写成 `提供方/模型` 的家，只对 id 会认错或认不出）
    var currentOption: ModelOption? { currentModel.flatMap { current in models.first { $0.key == key(current) } } }

    /// 配置项里的模型值读成模型键（`AgentKind.modelKey`；下发时反过来写成 `AgentKind.modelRef`）
    func key(_ model: String) -> ModelKey { agent.modelKey(model) ?? ModelKey(provider: "", id: model) }

    /// 换掉一项（`session/set_config_option`）：Agent 不认这个值时抛 `ACPError.server`，在用的不变。
    func set(_ category: String, to value: String) async throws {
        guard let sessionID, let config = option(category)?["id"]?.string else { throw HostedSessionError.rejected(String(localized: "\(agent.name) 不能换这一项")) }
        let result = try await live.call("session/set_config_option", ["sessionId": .string(sessionID), "configId": .string(config), "value": .string(value)])
        if let updated = result["configOptions"]?.array { adopt(options: updated) }
    }

    /// 就地换模型、强度（强度夹到换完之后的模型有的档位）；记下换过的，开新会话后再交一次（`HostedSession.configure`）。
    func configure(model: String?, effort: ThinkingLevel?) async throws {
        if let model { try await set("model", to: model) }
        if let effort { try await set("thought_level", to: effort.clamped(to: levels).rawValue) }
        configured = (model ?? configured.model, effort ?? configured.effort)
    }

    func adopt(options updated: [JSONValue]) {
        options = updated
        contextWindow = currentModel.flatMap { dialect.window(of: $0, in: opened) } ?? contextWindow
        guard let id else { return }
        bridge?.update(id) { publishOptions(to: &$0) }
    }

    func publishOptions(to session: inout Session) {
        session.availableModels = models
        session.model = currentOption
        session.thinking = currentLevel.map(Open.known)
    }
}
#endif
