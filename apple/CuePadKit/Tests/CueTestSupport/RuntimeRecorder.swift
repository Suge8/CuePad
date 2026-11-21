import CueStore
import Foundation

/// 测试里"这次开机"的标识：模拟器上没有系统启动标识（`SystemBoot.id` 为 nil），用一个固定的。
public enum TestBoot {
  public static let id = SystemBoot.id ?? "test-boot"
}

extension CueStore {
  public func runtimeRecorder(
    on host: String, boot: String = TestBoot.id, minInterval: Duration = StateRecorder.detailInterval, timing: Timing = .system
  ) throws -> StateRecorder {
    _ = try recordMacPresence(host: host, bootID: boot) { true }
    return StateRecorder(store: self, hostID: host, minInterval: minInterval, timing: timing, bootID: boot)
  }
}
