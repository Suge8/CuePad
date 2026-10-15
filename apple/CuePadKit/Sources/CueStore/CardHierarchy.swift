import Foundation

/// 卡片上下级里的环怎么断：远端并发地挪动留下的环（还没收敛），每个环里 id 最小的（按小写 UUID 字符串比）离开上级、回到顶层，
/// 各设备断成同一个样子。库收敛时（`CardLinks.repairs`）与界面排任务树时（App 的 `TaskTree`）都按这里断：
/// 远端变更刚到、库还没收敛的那一刻，界面上看到的已经是收敛后的样子。
public enum CardHierarchy {
  /// `parents` 是 id → 上级；上级不在其中的照原样留着（调用方按顶层看待）。返回断好环的上下级。
  /// `starts` 给了时只断从这些 id 往上走得到的环（收敛只看这次变更涉及的那一片），不给是全部。
  /// 每张卡只有一个上级，一片相连的卡至多一个环：断开它，这一片往上就都走得到头。
  public static func breakingCycles(_ parents: [UUID: UUID], from starts: [UUID]? = nil) -> [UUID: UUID] {
    var parents = parents
    for start in starts ?? Array(parents.keys) {
      var path = [start], cursor = parents[start]
      while let parent = cursor {
        if let index = path.firstIndex(of: parent) {
          if let breaker = path[index...].min(by: { $0.uuidString.lowercased() < $1.uuidString.lowercased() }) { parents[breaker] = nil }
          break
        }
        path.append(parent)
        cursor = parents[parent]
      }
    }
    return parents
  }
}
