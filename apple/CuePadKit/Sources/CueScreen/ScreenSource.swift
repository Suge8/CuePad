#if os(macOS)
import CoreVideo

/// 一块能看、能点的屏（模拟器的屏）：`ScreenServer` 把它变成本机网页。
public protocol ScreenSource: AnyObject, Sendable {
  /// 画面有改动就调 `changed`（哪条线程都行，可以比真改动多），一直到进程退出。
  func watch(_ changed: @escaping @Sendable () -> Void)
  /// 此刻的画面，自己的一份：来源那块缓冲会被原地改写，编码是异步的，不拷出来会编进半帧。屏没了是 nil。
  func frame() -> CVPixelBuffer?
  func send(_ input: ScreenInput)
}

/// 坐标与位移都按屏的宽高归一（0…1）。
public enum ScreenInput: Sendable {
  case touch(Phase, x: Double, y: Double)
  /// 滚轮、触控板双指：内容要走的那一段（往下滚是正的），`x`、`y` 是指针所在。
  case wheel(x: Double, y: Double, dx: Double, dy: Double)
  /// 键盘上一颗键按下、抬起：USB HID 键盘页（0x07）的用法码。
  case key(usage: UInt32, down: Bool)

  public enum Phase: String, Sendable { case down, move, up }
}
#endif
