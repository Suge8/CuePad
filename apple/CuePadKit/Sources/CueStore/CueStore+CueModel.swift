import Foundation

extension CueStore {
  /// Cue 写的 model（start、say 与 setup set 都经这里，唯一的核对）：照这家的写法读出键，再对清单——给了会话就是它的（`catalog(of:)`），
  /// 否则是那台 Mac 上这家的（`MacAgents`）。不在清单里的当场退回、列出能选的，不写成投送请求：等 Mac 那边才发现找不到时 Cue 早已收工，
  /// 会话也没换成。没有清单的（OpenCode）只核写法。
  public func cueModelKey(_ ref: String, of kind: AgentKind, host: String, session: String? = nil) throws -> ModelKey {
    let key = try kind.requiredModelKey(ref)
    let models = try session.flatMap { try sessionState($0) }.flatMap { try catalog(of: $0) }?.models ?? macAgents(on: host).agent(kind)?.models ?? []
    guard models.isEmpty || models.contains(where: { $0.key == key }) else {
      throw CueStoreError.unknownModel(agent: kind.name, model: ref, choices: models.map { kind.modelRef($0.key) })
    }
    return key
  }
}
