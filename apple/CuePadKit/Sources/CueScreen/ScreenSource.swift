#if os(macOS)
import CoreVideo

/// 一块能看、能点的屏（模拟器的屏、Mac 应用的窗口）：`ScreenServer` 把它变成本机网页。
public protocol ScreenSource: AnyObject, Sendable {
  /// 有人在看了：画面有改动就调 `changed`（哪条线程都行，可以比真改动多），到 `rest` 为止。
  func watch(_ changed: @escaping @Sendable () -> Void)
  /// 没人看了：不用再取画面。
  func rest()
  /// 此刻的画面，交出去之后不会再变：编码是异步的，来源那块缓冲会被原地改写的要拷一份，不然编进半帧。还没有画面是 nil。
  func frame() -> CVPixelBuffer?
  func send(_ input: ScreenInput)
}

/// 坐标与位移都按画面的宽高归一（0…1）。
public enum ScreenInput: Sendable {
  /// 一根手指，或鼠标左键。
  case touch(Phase, x: Double, y: Double)
  /// 鼠标右键点一下：桌面窗口出这一点的菜单，触摸屏没有这回事。
  case secondary(x: Double, y: Double)
  /// 滚轮、触控板双指：内容要走的那一段（往下滚是正的），`x`、`y` 是指针所在。
  case wheel(x: Double, y: Double, dx: Double, dy: Double)
  /// 键盘上一颗键按下、抬起：USB HID 键盘页（0x07）的用法码。
  case key(usage: UInt32, down: Bool)
  /// 打出来的一段字（看的那一头的输入法已经组好）。
  case text(String)

  public enum Phase: String, Sendable { case down, move, up }
}
#endif
