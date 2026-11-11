import CueStore
import Foundation

/// 测试里"这次开机"的标识：模拟器上没有系统启动标识（`SystemBoot.id` 为 nil），用一个固定的。
public enum TestBoot {
  public static let id = SystemBoot.id ?? "test-boot"
}

extension CueStore {
  /// 替 `host` 那台 Mac 写下"醒着、这次开机"并返回它的会话状态记录器：会话状态只在宿主在线、同一次开机报的才算数
  /// （`runtimeIsConfirmed`）。
  /// 不在历史回填时调用；要演重启或离线的用例自行改在线记录。
  public func runtimeRecorder(
    on host: String, boot: String = TestBoot.id, minInterval: Duration = StateRecorder.detailInterval, timing: Timing = .system
  ) throws -> StateRecorder {
    _ = try recordMacPresence(host: host, bootID: boot) { true }
    return StateRecorder(store: self, hostID: host, minInterval: minInterval, timing: timing, bootID: boot)
  }
}
