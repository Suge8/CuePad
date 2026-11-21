import Foundation

extension CueProfile {
  public func needsNewBrain(from current: CueProfile) -> Bool {
    name != current.name || runtime != current.runtime || fast != current.fast || (model == nil && current.model != nil)
      || (effort?.known == nil && current.effort?.known != nil)
  }
}
