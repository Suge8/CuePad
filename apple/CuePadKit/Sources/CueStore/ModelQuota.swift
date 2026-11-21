import Foundation

extension ModelOption {
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
