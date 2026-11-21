#if os(macOS)
import CoreVideo
import CueScreen
import Foundation
import IOSurface
@preconcurrency import XPC
import os

/// 一台开着的 iOS 模拟器的屏：画面直接读模拟器服务里那块帧缓冲，手指与按键经它的输入通道送进去。
/// 用的是 CoreSimulator、SimulatorKit 里没公开的接口（Xcode 自己的模拟器窗口、idb、AXe、serve-sim 走的同一条）：公开的只有 `simctl` 连拍，
/// 每秒两三张、不能点（实测 Xcode 27.2）。全经运行时按名字取，不链接：Xcode 换位置、换版本只在这个文件里坏，坏了报出是哪个名字没了。
/// 只在 `cuepad __screen` 那个后台进程里用：它崩了、Xcode 升级后认不得了，都碰不到 CuePad。
///
/// 输入有两条通道。iOS 27 起模拟器里有 `dtuhidd`（Xcode 27 的 Device Hub 用它）：它一接管，老的 Indigo 那条就收不到了
/// （实测 Xcode 27.2：同一台模拟器重开后老通道发得出去、界面没反应），所以有它就走它（`Hub`）；老系统的模拟器没有它，走 Indigo（`Legacy`），只有手指。
final class SimScreen: ScreenSource, @unchecked Sendable {
  struct Device: Sendable {
    let udid: String
    let name: String
  }

  struct Unsupported: Error, CustomStringConvertible {
    let description: String
    init(_ missing: String) { description = "这台 Mac 的 Xcode 里找不到 \(missing)：模拟器的接口换了，这一版 CuePad 认不得" }
  }

  let device: Device
  let tall: Bool
  private let simulator: NSObject
  private let display: NSObject
  private let surface: OSAllocatedUnfairLock<IOSurface>
  private let legacy: Legacy?
  private var hub: xpc_connection_t?
  private let input = DispatchQueue(label: "cuepad.screen.input", qos: .userInteractive)
  private let changed = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
  private var registered = false
  private var pool: CVPixelBufferPool?
  private var pooled = (width: 0, height: 0)
  private var scroll: (x: Double, y: Double)?
  private var scrollEnd: DispatchWorkItem?

  // MARK: 找设备

  static func booted() throws -> [Device] {
    try devices().filter { $0.value(forKey: "state") as? Int == bootedState }.map(describe)
  }

  private static let bootedState = 3

  private static func describe(_ simulator: NSObject) -> Device {
    Device(udid: (simulator.value(forKey: "UDID") as? UUID)?.uuidString ?? "", name: simulator.value(forKey: "name") as? String ?? "")
  }

  private static func devices() throws -> [NSObject] {
    let developer = developerDirectory
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)
    // SimulatorKit 在 Xcode 27 从 Developer/Library/PrivateFrameworks 挪到了 Contents/SharedFrameworks
    for path in ["\(developer)/../SharedFrameworks", "\(developer)/Library/PrivateFrameworks"] { dlopen("\(path)/SimulatorKit.framework/SimulatorKit", RTLD_NOW) }
    guard let context = NSClassFromString("SimServiceContext") as AnyObject? else { throw Unsupported("SimServiceContext") }
    guard let service = context.perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"), with: developer, with: nil)?.takeUnretainedValue(),
          let set = service.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue() as? NSObject,
          let devices = set.value(forKey: "devices") as? [NSObject] else { throw Unsupported("模拟器的设备清单") }
    return devices
  }

  private static var developerDirectory: String {
    ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? "/Applications/Xcode.app/Contents/Developer"
  }

  // MARK: 接上

  init(udid: String) throws {
    guard let simulator = try Self.devices().first(where: { Self.describe($0).udid == udid }), simulator.value(forKey: "state") as? Int == Self.bootedState else {
      throw CLIError.invalid("模拟器 \(udid) 没开着")
    }
    self.simulator = simulator
    device = Self.describe(simulator)

    let renderable = NSProtocolFromString("SimDisplayIOSurfaceRenderable")
    let ports = (simulator.value(forKey: "io") as? NSObject)?.value(forKey: "ioPorts") as? [NSObject] ?? []
    let screens = ports.compactMap { port -> (NSObject, IOSurface)? in
      guard let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject, let renderable, descriptor.conforms(to: renderable),
            let surface = Self.framebuffer(descriptor) else { return nil }
      return (descriptor, surface)
    }
    // 外接屏、CarPlay 也在里面：主屏是最大的那块
    guard let main = screens.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else { throw Unsupported("模拟器的屏（SimDisplayIOSurfaceRenderable）") }
    display = main.0
    surface = OSAllocatedUnfairLock(uncheckedState: main.1)
    tall = main.1.height * 10 > main.1.width * 16

    legacy = Self.hubPort(simulator) == 0 ? try Legacy(simulator) : nil
  }

  var isBooted: Bool { simulator.value(forKey: "state") as? Int == Self.bootedState }

  private static func framebuffer(_ descriptor: NSObject) -> IOSurface? {
    descriptor.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() as? IOSurface
  }

  // MARK: 画面

  /// 回调只登记一次、没人看时也留着：换缓冲那一条要一直听，不然歇着时转了屏，回来读的还是旧的那块。
  func watch(_ changed: @escaping @Sendable () -> Void) {
    self.changed.withLock { $0 = changed }
    guard !registered else { return }
    registered = true
    let id = NSUUID()
    // 模拟器换一块缓冲（转屏、重启界面）时告诉这里；平时原地改写同一块，改了哪几块矩形经 damage 回调来
    let swapped: @convention(block) (IOSurface?, IOSurface?) -> Void = { [surface, weak self] unmasked, _ in
      if let unmasked { surface.withLockUnchecked { $0 = unmasked } }
      self?.changed.withLock { $0 }?()
    }
    let damaged: @convention(block) (NSArray?) -> Void = { [weak self] _ in self?.changed.withLock { $0 }?() }
    typealias Register = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
    for (name, block) in [("registerCallbackWithUUID:ioSurfacesChangeCallback:", swapped as AnyObject), ("registerCallbackWithUUID:damageRectanglesCallback:", damaged as AnyObject)] {
      let selector = NSSelectorFromString(name)
      guard display.responds(to: selector) else { continue }
      unsafeBitCast(display.method(for: selector), to: Register.self)(display, selector, id, block)
    }
  }

  func rest() { changed.withLock { $0 = nil } }

  func frame() -> CVPixelBuffer? {
    let surface = surface.withLockUnchecked { $0 }
    if pooled != (surface.width, surface.height) {
      pooled = (surface.width, surface.height)
      let attributes: [CFString: Any] = [
        kCVPixelBufferWidthKey: surface.width, kCVPixelBufferHeightKey: surface.height, kCVPixelBufferPixelFormatTypeKey: surface.pixelFormat, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      ]
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }
    var copy: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy) == kCVReturnSuccess, let copy else { return nil }
    surface.lock(options: .readOnly, seed: nil)
    CVPixelBufferLockBaseAddress(copy, [])
    if let to = CVPixelBufferGetBaseAddress(copy) {
      let rows = min(surface.height, CVPixelBufferGetHeight(copy)), stride = min(surface.bytesPerRow, CVPixelBufferGetBytesPerRow(copy))
      if surface.bytesPerRow == CVPixelBufferGetBytesPerRow(copy) {
        memcpy(to, surface.baseAddress, rows * stride)
      } else {
        for row in 0..<rows { memcpy(to + row * CVPixelBufferGetBytesPerRow(copy), surface.baseAddress + row * surface.bytesPerRow, stride) }
      }
    }
    CVPixelBufferUnlockBaseAddress(copy, [])
    surface.unlock(options: .readOnly, seed: nil)
    return copy
  }

  // MARK: 手指与按键

  func send(_ input: ScreenInput) {
    self.input.async { [self] in
      switch input {
      case .touch(let phase, let x, let y):
        endScroll()
        if phase == .down { fromBottom = y > Self.bottomEdge }
        finger(phase, x, y)
      case .wheel(let x, let y, let dx, let dy): wheel(x, y, dx, dy)
      case .key(let usage, let down): post("IndigoKeyboardButtonEvent", ["usageCode": UInt64(usage), "state": UInt64(down ? 1 : 2)])
      case .secondary, .text, .focus, .fill: break
      }
    }
  }

  /// 从屏的最下沿按下的那一次拖动带上"下边缘"：全面屏上往上一划是回主屏幕，不带它 iOS 当成普通的拖。
  private static let bottomEdge = 0.97
  private var fromBottom = false

  private func finger(_ phase: ScreenInput.Phase, _ x: Double, _ y: Double) {
    let x = min(1, max(0, x)), y = min(1, max(0, y)), edge: UInt64 = fromBottom ? 3 : 0
    if let legacy { return legacy.touch(phase, x, y, edge: UInt32(edge)) }
    let event: UInt64 = switch phase { case .down: 0 case .move: 1 case .up: 2 }
    post("IndigoDigitizerEvent", ["pointOne": ["x": x, "y": y], "eventType": event, "edge": edge, "target": UInt64(0)])
  }

  // MARK: dtuhidd

  private static let hubService = "com.apple.coredevice.feature.remote.hid.digitizer"

  private static func hubPort(_ simulator: NSObject) -> mach_port_t {
    let lookup = NSSelectorFromString("lookup:error:")
    typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> mach_port_t
    guard simulator.responds(to: lookup) else { return 0 }
    return unsafeBitCast(simulator.method(for: lookup), to: Lookup.self)(simulator, lookup, hubService as NSString, nil)
  }

  private func post(_ kind: String, _ payload: [String: Any]) {
    guard let hub = hub ?? connect() else { return }
    xpc_connection_send_message(hub, Self.xpc(["messageType": kind, "isBarrier": false, "featureIdentifier": Self.hubService, "payload": payload]))
  }

  private func connect() -> xpc_connection_t? {
    typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    typealias Connection = @convention(c) (xpc_object_t) -> xpc_connection_t?
    typealias Enable = @convention(c) (xpc_connection_t) -> Void
    let everything = UnsafeMutableRawPointer(bitPattern: -2)
    let port = Self.hubPort(simulator)
    guard port != 0, let endpoint = dlsym(everything, "xpc_endpoint_create_mach_port_4sim"), let create = dlsym(everything, "xpc_connection_create_from_endpoint"),
          let enable = dlsym(everything, "xpc_connection_enable_sim2host_4sim"),
          let made = unsafeBitCast(endpoint, to: Endpoint.self)(port, 0, 0).flatMap(unsafeBitCast(create, to: Connection.self)) else { return nil }
    // 不标成"模拟器到宿主"的连接，那头看得到有人连上、收不到内容
    unsafeBitCast(enable, to: Enable.self)(made)
    xpc_connection_set_event_handler(made) { [weak self] event in
      if xpc_get_type(event) == XPC_TYPE_ERROR { self?.hub = nil }
    }
    xpc_connection_set_target_queue(made, input)
    xpc_connection_resume(made)
    hub = made
    return made
  }

  /// `dtuhidd` 按类型解：整数要是无符号 64 位，给成字符串、有符号的它不认。
  private static func xpc(_ value: Any) -> xpc_object_t {
    switch value {
    case let value as String: return xpc_string_create(value)
    case let value as Bool: return xpc_bool_create(value)
    case let value as UInt64: return xpc_uint64_create(value)
    case let value as Double: return xpc_double_create(value)
    case let value as [String: Any]:
      let dictionary = xpc_dictionary_create_empty()
      for (key, item) in value { xpc_dictionary_set_value(dictionary, key, xpc(item)) }
      return dictionary
    default: return xpc_null_create()
    }
  }

  // MARK: 滚轮

  /// 模拟器里没有滚轮（它的屏就是一块触摸屏，合成的滚动事件 iOS 不收）：一串滚轮变成一次拖动，手指从指针那里按下、反着内容走，
  /// 停了 `wheelIdle` 抬起；快走出屏了就抬起、回到指针那里再按下接着拖。
  private func wheel(_ x: Double, _ y: Double, _ dx: Double, _ dy: Double) {
    scrollEnd?.cancel()
    var at = scroll ?? (x, y)
    if scroll == nil { finger(.down, at.x, at.y) }
    at = (at.x - dx, at.y - dy)
    if !(0.05...0.95).contains(at.x) || !(0.05...0.95).contains(at.y) {
      finger(.up, min(1, max(0, at.x)), min(1, max(0, at.y)))
      finger(.down, x, y)
      at = (x, y)
    } else {
      finger(.move, at.x, at.y)
    }
    scroll = at
    let end = DispatchWorkItem { [weak self] in self?.endScroll() }
    scrollEnd = end
    self.input.asyncAfter(deadline: .now() + Self.wheelIdle, execute: end)
  }

  private func endScroll() {
    scrollEnd?.cancel()
    guard let at = scroll else { return }
    scroll = nil
    finger(.up, at.x, at.y)
  }

  private static let wheelIdle = DispatchTimeInterval.milliseconds(100)
}

/// iOS 27 以前的输入通道（SimulatorKit 的 Indigo）：只送手指。
private final class Legacy {
  /// (点, 第二根手指, 目标, NSEventType, NSSize 的宽, 高, 边缘) → 一条消息，发完由通道释放。
  private typealias Make = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, UInt, CGFloat, CGFloat, UInt32) -> UnsafeMutableRawPointer?
  private let make: Make
  private let client: NSObject

  init(_ simulator: NSObject) throws {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForMouseNSEvent") else { throw SimScreen.Unsupported("IndigoHIDMessageForMouseNSEvent") }
    make = unsafeBitCast(symbol, to: Make.self)
    let create = NSSelectorFromString("initWithDevice:error:")
    guard let type = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient"), let method = class_getMethodImplementation(type, create) else {
      throw SimScreen.Unsupported("SimDeviceLegacyHIDClient")
    }
    var failure: NSError?
    typealias Create = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let client = unsafeBitCast(method, to: Create.self)(type.alloc(), create, simulator, &failure) as? NSObject else {
      throw SimScreen.Unsupported("模拟器的输入通道（\(failure?.localizedDescription ?? "SimDeviceLegacyHIDClient")）")
    }
    self.client = client
  }

  /// 0x32：触摸屏这个输入目标。NSEventType 只认按下（1）与抬起（2），移动也发按下；宽高给 1，点就是归一后的比例。
  func touch(_ phase: ScreenInput.Phase, _ x: Double, _ y: Double, edge: UInt32) {
    var point = CGPoint(x: x, y: y)
    guard let message = make(&point, nil, 0x32, phase == .up ? 2 : 1, 1, 1, edge) else { return }
    let send = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
    unsafeBitCast(client.method(for: send), to: Send.self)(client, send, message, true, nil, nil)
  }
}
#endif
