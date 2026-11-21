#if os(macOS)
import AppKit

/// 点与键：在进程里造成 NSEvent 排进应用的事件队列，不经窗口服务器。不动真鼠标，应用在后台、窗口被挡着都照样收到。
/// 排进队列、不直接交给窗口：之后是谁在取事件（平常的循环、按钮与滑块的跟踪循环、开着的菜单、模态面板），就由谁照常处理；
/// 走到平常派发的先过 `dispatch`，补上后台应用缺的那两步。
/// 收不到的是窗口服务器自己管的那几样：拖标题栏挪窗口、拖边缘改大小、指针悬停的效果。
extension WindowScreen {
  struct Input {
    /// 按下那一下落在哪扇窗：拖动与抬起都算它的，指针出了窗口也是。
    var pressed: NSWindow?
    /// 最近点过的那扇窗：键与字交给它（`typing`）。应用在后台时没有"当前窗口"可问。
    weak var focus: NSWindow?
    /// 点那一下时画面里有哪些窗。
    var around: Set<Int> = []
    var modifiers: NSEvent.ModifierFlags = []
    var clicks = (at: CGPoint.zero, time: 0.0, count: 0)
    var number = 0
    /// 滚轮攒着的不足一个像素的零头。
    var scroll = CGSize.zero
    /// 最近一下输入是哪一刻：`outline` 等它过去一会儿再答。
    var time = 0.0
  }

  @MainActor func deliver(_ event: ScreenInput) {
    input.time = CACurrentMediaTime()
    switch event {
    case .touch(.down, let x, let y): press(x, y)
    case .touch(.move, let x, let y): drag(.leftMouseDragged, x, y)
    case .touch(.up, let x, let y):
      drag(.leftMouseUp, x, y)
      input.pressed = nil
    case .secondary(let x, let y):
      guard let point = place(x, y)?.point, let window = window(at: point) else { return }
      post(.rightMouseDown, in: window, at: point)
      post(.rightMouseUp, in: window, at: point)
    case .wheel(let x, let y, let dx, let dy): scroll(x, y, dx, dy)
    case .key(let usage, let down): key(usage, down)
    case .text(let text): insert(text)
    case .focus(let id): focus(id)
    case .fill(let id, let text): fill(id, text)
    }
  }

  // MARK: 画面与窗口

  /// 画面里有哪些窗，从底下往上：那扇窗、挂在它上面的（表单、弹层），再是菜单（它不挂在谁上面，排在菜单那一层）。
  /// 别的窗不在画面里：别的普通窗口、自己浮着的面板（放到菜单那一层的也不在，实测）。ScreenCaptureKit 没说它把哪些算进来，这是照实测对出来的。
  @MainActor var stack: [NSWindow] {
    func chain(_ window: NSWindow) -> [NSWindow] { [window] + ((window.parent ?? window.sheetParent).map(chain) ?? []) }
    return NSApp.windows.compactMap { window -> (NSWindow, Int, Int)? in
      guard window.isVisible, let root = chain(window).last, root === shown || level(root) == .popUpMenu else { return nil }
      return (window, level(root).rawValue, chain(window).count)
    }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
  }

  /// 画面对着屏上的哪一块（AppKit 的坐标：左下原点）：`all` 等比缩成 `scale` 倍、靠左上摆进 `window` 那么大的画面里。
  /// 画面平常就是窗口本身；有窗伸出去时（靠边的菜单，它的影子那一圈也算；流报的，`overflowing`），
  /// ScreenCaptureKit 把 `stack` 的外接矩形等比缩进来（实测）。
  @MainActor var picture: (all: CGRect, window: CGRect, scale: Double)? {
    guard let frame = shown?.frame else { return nil }
    let all = overflowing ? stack.reduce(frame) { $0.union($1.frame) } : frame
    return (all, frame, min(frame.width / all.width, frame.height / all.height))
  }

  /// 画面里的一点 → 屏上的一点，与画面缩了多少。
  @MainActor private func place(_ x: Double, _ y: Double) -> (point: CGPoint, scale: Double)? {
    picture.map { (CGPoint(x: $0.all.minX + x * $0.window.width / $0.scale, y: $0.all.maxY - y * $0.window.height / $0.scale), $0.scale) }
  }

  /// 这一点上最上面的那扇窗。挂着表单的那扇不算：同真鼠标一样点不动它，键盘也留在表单那里。
  @MainActor func window(at point: CGPoint) -> NSWindow? { stack.last { !$0.ignoresMouseEvents && $0.attachedSheet == nil && $0.frame.contains(point) } }

  // MARK: 鼠标

  @MainActor private func post(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint) {
    input.number += 1
    // 记号要打在 CGEvent 上再变回 NSEvent：直接打在 `NSEvent.cgEvent` 上的留不住（实测）；窗口、位置、连击数这一来一回都还在
    guard let made = NSEvent.mouseEvent(
      with: type, location: window.convertPoint(fromScreen: point), modifierFlags: input.modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: input.number, clickCount: input.clicks.count, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1), let marked = made.cgEvent else { return }
    marked.setIntegerValueField(.eventSourceUserData, value: Self.mark)
    guard let event = NSEvent(cgEvent: marked) else { return }
    NSApp.postEvent(event, atStart: false)
  }

  /// 没落在哪扇窗上的点（窗口外的空处）算给最近点过的那扇：开着的菜单照常收起。
  @MainActor private func press(_ x: Double, _ y: Double) {
    guard let point = place(x, y)?.point, let window = window(at: point) ?? typing else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let again = now - input.clicks.time < NSEvent.doubleClickInterval && hypot(point.x - input.clicks.at.x, point.y - input.clicks.at.y) < 4
    input.clicks = (point, now, again ? input.clicks.count + 1 : 1)
    input.pressed = window
    input.focus = window
    input.around = Set(stack.map(\.windowNumber))
    post(.leftMouseDown, in: window, at: point)
  }

  @MainActor private func drag(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
    guard let window = input.pressed, let point = place(x, y)?.point else { return }
    post(type, in: window, at: point)
  }

  /// 滚轮事件不带窗口，经窗口派发时落不到指针下的视图上（实测）：直接交给这一点下的视图。
  @MainActor private func scroll(_ x: Double, _ y: Double, _ dx: Double, _ dy: Double) {
    guard let frame = shown?.frame, let (point, scale) = place(x, y), let window = window(at: point) else { return }
    input.scroll.width -= dx * frame.width / scale
    input.scroll.height -= dy * frame.height / scale
    let whole = (x: input.scroll.width.rounded(.towardZero), y: input.scroll.height.rounded(.towardZero))
    guard whole.x != 0 || whole.y != 0 else { return }
    input.scroll.width -= whole.x
    input.scroll.height -= whole.y
    guard let made = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(whole.y), wheel2: Int32(whole.x), wheel3: 0), let event = NSEvent(cgEvent: made) else { return }
    (window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: point)) ?? window.contentView)?.scrollWheel(with: event)
  }

  // MARK: 键与字

  /// 键与字给哪扇窗，照真的当前窗口那样：点过之后才开出来的（表单、弹层）拿走键盘；没有这样的，最近点过的那扇还在画面里就是它；
  /// 都不是就给画面里最上面能拿键盘的（换过去的设置窗、表单关了之后底下那扇）。
  @MainActor var typing: NSWindow? {
    let keyable = stack.filter(\.canBecomeKey)
    return keyable.last { !input.around.contains($0.windowNumber) } ?? keyable.last { $0 === input.focus } ?? keyable.last
  }

  @MainActor private func key(_ usage: UInt32, _ down: Bool) {
    if let modifier = Self.modifiers[usage] {
      if down { input.modifiers.insert(modifier) } else { input.modifiers.remove(modifier) }
      return
    }
    guard let code = Self.keyCodes[usage], let made = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
    // 这颗键在当前键盘布局下的字符由系统填（方向键、功能键的标志也是）；修饰键照看的那一头按着的
    made.flags.formUnion(CGEventFlags(rawValue: UInt64(input.modifiers.rawValue)))
    made.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    made.setIntegerValueField(.eventSourceUserData, value: Self.mark)
    guard let event = NSEvent(cgEvent: made) else { return }
    NSApp.postEvent(event, atStart: false)
  }

  /// 字直接插进拿着键盘的那个输入框：不照键位送，不然这台 Mac 当前的输入法会在后台的应用里再组一遍。
  @MainActor func insert(_ text: String) {
    guard let window = typing else { return }
    if let client = window.firstResponder as? any NSTextInputClient { return client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    // 拿着键盘的不是输入框（按字母键当快捷键的界面）：一个字一下按键
    for character in text {
      for phase in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(
          with: phase, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0) else { continue }
        window.sendEvent(event)
      }
    }
  }

  // MARK: 派发

  /// 这里造的事件带这个记号（`CGEvent` 的 `eventSourceUserData`）：`dispatch` 凭它认，真鼠标真键盘的不碰。
  private static let mark: Int64 = 0x43_7565

  /// 应用平常派发按下与键之前先过这里（`NSEvent.addLocalMonitorForEvents`，`WindowScreen.init` 装的）。应用在后台时哪扇窗都不是当前窗口：
  /// 按下，AppKit 先问落点的视图接不接第一下（`acceptsFirstMouse`），不接的（文本框、带手势的 SwiftUI 视图）就只当成"点到这扇窗"；
  /// 键，没有当前窗口可给，直接丢掉。按下：让那个视图对这里造的事件答"接"，之后照常派发；键：给拿键盘的那扇窗，原来那一下吞掉。
  @MainActor func dispatch(_ event: NSEvent) -> NSEvent? {
    guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.mark else { return event }
    if event.type == .leftMouseDown {
      if let window = event.window, !window.isKeyWindow, let view = window.contentView?.superview?.hitTest(event.locationInWindow) { Self.welcome(type(of: view)) }
      return event
    }
    if !event.modifierFlags.isDisjoint(with: [.command, .control]), event.type == .keyDown { shortcut(event) } else { typing?.sendEvent(event) }
    return nil
  }

  /// 这个类的视图对这里造的事件一律答"接第一下"，别的事件照它原来的答。
  /// 改的是这一个类的方法：没有公开的口子让后台应用的窗口当上当前窗口（`makeKey` 不作数，实测 macOS 27.2），
  /// 而自己替 AppKit 调 `mouseDown` 的话手势认不到（它们是 AppKit 派发时喂的，SwiftUI 的点按、拖、双击都是手势）。
  @MainActor private static func welcome(_ type: AnyClass) {
    let selector = #selector(NSView.acceptsFirstMouse(for:))
    guard welcomed.insert(ObjectIdentifier(type)).inserted, let method = class_getInstanceMethod(type, selector) else { return }
    typealias Original = @convention(c) (NSView, Selector, NSEvent?) -> Bool
    let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
    let ours: @convention(block) (NSView, NSEvent?) -> Bool = { view, event in
      event?.cgEvent?.getIntegerValueField(.eventSourceUserData) == mark || original(view, selector, event)
    }
    class_replaceMethod(type, selector, imp_implementationWithBlock(ours), method_getTypeEncoding(method))
  }

  @MainActor private static var welcomed: Set<ObjectIdentifier> = []

  /// 带 ⌘ ⌃ 的键照 AppKit 平常的次序问一遍：拿键盘的那扇窗里的视图，再是菜单。应用在后台时菜单里靠当前窗口找目标的项（全选、撤销、关窗）都是灰的：
  /// 这种自己照键找出那一项，把它的动作顺着那扇窗的响应链送。
  @MainActor private func shortcut(_ event: NSEvent) {
    guard let window = typing, !window.performKeyEquivalent(with: event), NSApp.mainMenu?.performKeyEquivalent(with: event) != true else { return }
    let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
    func find(_ menu: NSMenu) -> NSMenuItem? {
      menu.items.lazy.compactMap { item -> NSMenuItem? in
        if let submenu = item.submenu { return find(submenu) }
        let key = item.keyEquivalent
        // 菜单项的键写成大写就是带 ⇧
        let wants = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]).union(key == key.lowercased() ? [] : .shift)
        return !key.isEmpty && key.lowercased() == event.charactersIgnoringModifiers?.lowercased() && wants == held ? item : nil
      }.first
    }
    if let item = NSApp.mainMenu.flatMap(find), let action = item.action, window.firstResponder?.tryToPerform(action, with: item) == true { return }
    window.sendEvent(event)
  }

  private static let modifiers: [UInt32: NSEvent.ModifierFlags] = [224: .control, 225: .shift, 226: .option, 227: .command, 228: .control, 229: .shift, 230: .option, 231: .command]

  /// USB HID 键盘页的用法码 → Mac 的虚拟键码（Carbon 的 kVK_*）。
  private static let keyCodes: [UInt32: CGKeyCode] = {
    let letters: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    let function: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    var codes: [UInt32: CGKeyCode] = [
      40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24, 47: 33, 48: 30, 49: 42, 51: 41, 52: 39, 53: 50, 54: 43, 55: 47, 56: 44, 57: 57,
      74: 115, 75: 116, 76: 117, 77: 119, 78: 121, 79: 124, 80: 123, 81: 125, 82: 126,
    ]
    for (index, code) in letters.enumerated() { codes[UInt32(4 + index)] = code }
    for (index, code) in digits.enumerated() { codes[UInt32(30 + index)] = code }
    for (index, code) in function.enumerated() { codes[UInt32(58 + index)] = code }
    return codes
  }()
}
#endif
