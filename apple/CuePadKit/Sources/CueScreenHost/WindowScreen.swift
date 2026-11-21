#if os(macOS)
import AppKit
import ScreenCaptureKit
import os

/// 这个应用最前面的那扇主窗口，连同挂在它上面的窗（表单、弹层、菜单）。
/// 画面经 ScreenCaptureKit 按窗口取（`desktopIndependentWindow`）：只列本进程内容的那一条不过授权（`SCShareableContent.currentProcess`），
/// 被别的窗口挡着、应用在后台、窗口在别的桌面照样出帧（实测；按显示器取的那一种窗口不在当前桌面时一帧都没有）。最小化、隐藏时没有画面。
/// 点与键见 `WindowScreen+Input`，画面里有什么见 `WindowScreen+Outline`。
final class WindowScreen: NSObject, ScreenSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  /// 取哪扇窗，画面多大（像素）。
  struct Stage: Equatable, Sendable {
    let window: CGWindowID
    let width: Int
    let height: Int
    /// 第几次起流：流自己停了、没起成，加一再量，同一扇窗也重起（`again`）。
    let turn: Int
  }

  private struct Shared {
    var changed: (@Sendable () -> Void)?
    var frame: CVPixelBuffer?
    /// `frame` 是哪一刻的。
    var time = 0.0
    /// 正起着的那条流：停下的通知是不是它的，凭这个认。
    var stream: SCStream?
    /// 最近一帧里有窗伸出了窗口（`place`）。
    var overflowing = false
  }

  private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())
  private let frames = DispatchQueue(label: "cuepad.screen.capture", qos: .userInteractive)
  /// 要取的那一块（没人看、没有窗口是 nil）：只留最新的，`capture` 一个个照着改流。
  private let wanted: AsyncStream<Stage?>.Continuation
  @MainActor private var asked: Stage?
  @MainActor private var turn = 0
  @MainActor private var watching = false
  /// 画面里的那扇窗。
  @MainActor private(set) weak var shown: NSWindow?
  /// 上一次量到开着的那些窗。
  @MainActor private var seen: Set<Int> = []
  /// 压到壁纸底下的窗各自原来在哪一层（`tuck`）。
  @MainActor private let levels = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
  @MainActor var input = Input()
  @MainActor var outlined = Outlined()

  @MainActor override init() {
    let (stages, wanted) = AsyncStream.makeStream(of: Stage?.self, bufferingPolicy: .bufferingNewest(1))
    self.wanted = wanted
    super.init()
    Task.detached { [weak self] in
      var stream: (SCStream, Stage)?
      for await stage in stages {
        guard let self else { return }
        stream = await self.capture(stage, from: stream)
      }
    }
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .keyUp]) { [weak self] event in
      guard let self else { return event }
      return dispatch(event)
    }
    // 窗口开、关、变大小都在应用处理完一轮事件之后：这时重新量一遍
    NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.tuck()
        self?.measure()
      }
    }
    // 菜单开着时应用不走上面那一轮：它的窗（子菜单也是）一露面就压下去
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.tuck() }
    }
  }

  /// 应用在后台时，它的窗都压在桌面壁纸底下，看它、点它都在预览里：画面照取，这里造的事件不经屏幕、照收，屏上不见它。
  /// 不压的话，后台的应用一开窗、挨一下点、出一个菜单，系统就把窗提到所有应用的窗口上面（实测 macOS 27.2），盖住正看着预览的 CuePad。
  /// 别的藏法都不行（实测）：最小化、隐藏、全透明就没有画面，挪到屏外被系统拉回来露一条边，排到所有窗口最底下还露在桌面上。
  /// 状态栏图标那一层不动。应用到前台（用户点它的程序坞图标）各回各层，退回后台再压下去。
  @MainActor private func tuck() {
    for window in NSApp.windows where window.parent == nil && window.sheetParent == nil && level(window) != .statusBar {
      if NSApp.isActive {
        guard let own = levels.object(forKey: window) else { continue }
        window.level = NSWindow.Level(own.intValue)
        levels.removeObject(forKey: window)
      } else if window.level != Self.under {
        levels.setObject(window.level.rawValue as NSNumber, forKey: window)
        window.level = Self.under
      }
    }
  }

  /// 这扇窗自己的那一层（压下去之前的）。
  @MainActor func level(_ window: NSWindow) -> NSWindow.Level {
    levels.object(forKey: window).map { NSWindow.Level($0.intValue) } ?? window.level
  }

  private static let under = NSWindow.Level(Int(CGWindowLevelForKey(.minimumWindow)))

  // MARK: ScreenSource

  func watch(_ changed: @escaping @Sendable () -> Void) {
    shared.withLockUnchecked { $0.changed = changed }
    onMain {
      $0.watching = true
      $0.measure()
      $0.outlines()
    }
  }

  func rest() {
    shared.withLockUnchecked {
      $0.changed = nil
      $0.frame = nil
      $0.time = 0
    }
    onMain {
      $0.watching = false
      $0.measure()
    }
  }

  func frame() -> CVPixelBuffer? { shared.withLockUnchecked { $0.frame } }

  /// 最近一帧里有窗伸出了窗口。
  var overflowing: Bool { shared.withLockUnchecked { $0.overflowing } }
  /// 最近一帧是哪一刻。
  var changed: Double { shared.withLockUnchecked { $0.time } }

  func send(_ input: ScreenInput) { onMain { $0.deliver(input) } }

  func outline(_ reply: @escaping @Sendable (Data?) -> Void) { onMain { $0.ask(reply) } }

  /// 回主线程做。排在运行循环上、不排主队列：按下那一下可能就地转起一个跟踪循环等抬起（`dispatch`），
  /// 主队列在自己的一块活里不会再往下取，抬起永远到不了（实测卡死在 NSTextView 的选字循环里）；运行循环嵌着转时照样取。
  func onMain(_ work: @escaping @MainActor @Sendable (WindowScreen) -> Void) {
    RunLoop.main.perform(inModes: [.common]) { [self] in
      MainActor.assumeIsolated { work(self) }
    }
  }

  // MARK: 取哪一块

  @MainActor private func measure() {
    var stage: Stage?
    if watching {
      // 能当主窗口的那些，从前往后；只有面板的应用（菜单栏小工具）取能拿键盘的
      let all = NSApp.orderedWindows.filter { $0.isVisible && $0.parent == nil && $0.sheetParent == nil }
      let open = all.contains(where: \.canBecomeMain) ? all.filter(\.canBecomeMain) : all.filter(\.canBecomeKey)
      // 新开的那扇（设置、新文档）换过去看，看着的那扇关了回到最前面的。不只看谁在最前面：后台的应用新开的窗排在自己别的窗后面（实测）
      let fresh = open.first { !seen.contains($0.windowNumber) }
      seen = Set(open.map(\.windowNumber))
      shown = fresh ?? open.first { $0 === shown } ?? open.first
      stage = shown.map {
        // 照窗口的像素取，长边不过 `longest`：再大编码与手机那头解码都白费。H.264 的宽高要是偶数
        let scale = min($0.backingScaleFactor, Self.longest / max($0.frame.width, $0.frame.height))
        return Stage(window: CGWindowID($0.windowNumber), width: Int($0.frame.width * scale / 2) * 2, height: Int($0.frame.height * scale / 2) * 2, turn: turn)
      }
    }
    guard stage != asked else { return }
    asked = stage
    wanted.yield(stage)
  }

  private static let longest = 2560.0

  // MARK: 取画面

  /// 把流改成取 `stage`：没有流就起，换了窗口、换了一次（`Stage.turn`）重起，同一扇窗只改大小；nil 是停。回来的是改完后的流。
  private func capture(_ stage: Stage?, from running: (stream: SCStream, stage: Stage)?) async -> (SCStream, Stage)? {
    do {
      if let running {
        if let stage, stage.window == running.stage.window, stage.turn == running.stage.turn {
          try await running.stream.updateConfiguration(Self.configuration(stage))
          return (running.stream, stage)
        }
        shared.withLockUnchecked { $0.stream = nil }
        // 流自己停了的那一种这里会报错，不管它
        try? await running.stream.stopCapture()
      }
      guard let stage else { return nil }
      // 刚开出来的窗 ScreenCaptureKit 可能还没列出
      guard let window = try await SCShareableContent.currentProcess.windows.first(where: { $0.windowID == stage.window }) else {
        again()
        return nil
      }
      let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: Self.configuration(stage), delegate: self)
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
      try await stream.startCapture()
      shared.withLockUnchecked { $0.stream = stream }
      return (stream, stage)
    } catch {
      Host.say("取不到画面：\(error)")
      shared.withLockUnchecked { $0.stream = nil }
      try? await running?.stream.stopCapture()
      again()
      return nil
    }
  }

  /// 没取成、流自己停了：过一秒当成新的一次再量，还有人看、窗口还在就重起。
  private func again() {
    Task { @MainActor [self] in
      try? await Task.sleep(for: .seconds(1))
      turn += 1
      measure()
    }
  }

  private static func configuration(_ stage: Stage) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = stage.width
    configuration.height = stage.height
    configuration.includeChildWindows = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.showsCursor = false
    // 手上留着上一帧（`same`），编码那头还可能拿着一帧
    configuration.queueDepth = 4
    return configuration
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
          (info[.status] as? Int).flatMap(SCFrameStatus.init) == .complete, let buffer = sample.imageBuffer else { return }
    // 按窗口取的流不管画面动没动都一直出帧，也不守 `minimumFrameInterval`（实测：不动时每秒四十来帧，每帧都标着整幅有改动；120 Hz 的屏上滚动时近百帧）。
    // 这里压到每秒 60 帧，和上一帧一样的不往下送：不动的画面不编码、不发。被压掉的那一帧不会就此丢了：画面停住后流还在出同样的帧，下一帧补上
    // 画面是窗口那么大；有窗伸出去时 ScreenCaptureKit 把它们的外接矩形等比缩进来，内容就不再铺满，宽高比对不上
    let content = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
    let overflowing = content.height > 0 && abs(content.width / content.height - Double(CVPixelBufferGetWidth(buffer)) / Double(CVPixelBufferGetHeight(buffer))) > 0.005
    let time = CACurrentMediaTime()
    let last = shared.withLockUnchecked {
      $0.overflowing = overflowing
      return ($0.frame, $0.time)
    }
    if time - last.1 < 1.0 / 61 { return }
    if let frame = last.0, Self.same(frame, buffer) { return }
    shared.withLockUnchecked {
      $0.frame = buffer
      $0.time = time
      return $0.changed
    }?()
  }

  private static func same(_ one: CVPixelBuffer, _ other: CVPixelBuffer) -> Bool {
    guard CVPixelBufferGetWidth(one) == CVPixelBufferGetWidth(other), CVPixelBufferGetHeight(one) == CVPixelBufferGetHeight(other) else { return false }
    CVPixelBufferLockBaseAddress(one, .readOnly)
    CVPixelBufferLockBaseAddress(other, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(one, .readOnly)
      CVPixelBufferUnlockBaseAddress(other, .readOnly)
    }
    return (0..<CVPixelBufferGetPlaneCount(one)).allSatisfy {
      let length = CVPixelBufferGetBytesPerRowOfPlane(one, $0) * CVPixelBufferGetHeightOfPlane(one, $0)
      return CVPixelBufferGetBytesPerRowOfPlane(other, $0) * CVPixelBufferGetHeightOfPlane(other, $0) == length
        && memcmp(CVPixelBufferGetBaseAddressOfPlane(one, $0), CVPixelBufferGetBaseAddressOfPlane(other, $0), length) == 0
    }
  }

  /// 流自己停了（系统收回）：重起。这里自己停掉的流（换窗、没人看）不算。
  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    guard shared.withLockUnchecked({ $0.stream === stream }) else { return }
    Host.say("画面停了：\(error)")
    again()
  }
}
#endif
