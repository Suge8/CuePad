import Foundation

extension CueStore {
  public func cueModelKey(_ ref: String, of kind: AgentKind, host: String, session: String? = nil) throws -> ModelKey {
    let key = try kind.requiredModelKey(ref)
    let models = try session.flatMap { try sessionState($0) }.flatMap { try catalog(of: $0) }?.models ?? macAgents(on: host).agent(kind)?.models ?? []
    guard models.isEmpty || models.contains(where: { $0.key == key }) else {
      throw CueStoreError.unknownModel(agent: kind.name, model: ref, choices: models.map { kind.modelRef($0.key) })
    }
    return key
  }
}
