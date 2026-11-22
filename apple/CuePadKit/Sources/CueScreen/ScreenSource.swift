#if os(macOS)
import CoreVideo

public protocol ScreenSource: AnyObject, Sendable {
  func watch(_ changed: @escaping @Sendable () -> Void)
  func rest()
  /// 此刻的画面，交出去之后不会再变：编码是异步的，来源那块缓冲会被原地改写的要拷一份，不然编进半帧。还没有画面是 nil。
  func frame() -> CVPixelBuffer?
  func send(_ input: ScreenInput)
  func outline(_ reply: @escaping @Sendable (Data?) -> Void)
}

extension ScreenSource {
  public func outline(_ reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }
}

public enum ScreenInput: Sendable {
  case touch(Phase, x: Double, y: Double)
  case secondary(x: Double, y: Double)
  case wheel(x: Double, y: Double, dx: Double, dy: Double)
  case key(usage: UInt32, down: Bool)
  case text(String)
  case focus(Int)
  case fill(Int, String)

  public enum Phase: String, Sendable { case down, move, up }
}
#endif
