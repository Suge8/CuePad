import Foundation

extension CueProfile {
  /// 从 `current` 改成这样要换新大脑（唯一的规则：值班的管理器据此换班次，Cue 的 `setup set` 据此说何时生效）：
  /// 名字在系统提示里、Agent 是另一个进程；fast、模型或强度回到这家的默认也要重开。其余（换模型、换强度）在大脑里就地换。
  public func needsNewBrain(from current: CueProfile) -> Bool {
    name != current.name || runtime != current.runtime || fast != current.fast || (model == nil && current.model != nil)
      || (effort?.known == nil && current.effort?.known != nil)
  }
}
