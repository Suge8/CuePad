import Foundation

extension PiModelOption {
  /// 这个模型花的是哪个账号的额度（`AccountQuota`），关联不上为 nil：回复框的模型胶囊、模型菜单的分组标题与 Cue 的 `setup look` 都只认这一条。
  /// 原生订阅按提供方与授权分区对上；网关只在模型明确指定完整上游（最长的 route 前缀）且只对上一个账号时关联，auto 与多个账号不猜实际路由；
  /// 网关的授权根本不报额度时给那条"不支持"的记录。
  public func quota(in quotas: [AccountQuota]) -> AccountQuota? {
    guard let account else { return nil }
    guard let source = account.source else {
      return quotas.first { $0.provider == key.provider && account.matches($0.account) }
    }
    let candidates = quotas.filter {
      $0.account?.source == source && $0.account?.route.map { key.id.hasPrefix($0 + "/") } == true
    }
    let longest = candidates.compactMap { $0.account?.route?.count }.max()
    let matching = candidates.filter { $0.account?.route?.count == longest }
    if let scope = matching.first?.account?.scope, matching.allSatisfy({ $0.account?.scope == scope }) {
      return matching.max {
        let first = $0.observedAt ?? .distantPast, second = $1.observedAt ?? .distantPast
        return first == second ? $0.modifiedAt < $1.modifiedAt : first < second
      }
    }
    return quotas.first { $0.account?.source == source && $0.account?.route == nil && $0.status == .unsupported }
  }
}
