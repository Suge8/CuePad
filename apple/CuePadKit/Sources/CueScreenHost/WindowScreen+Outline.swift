#if os(macOS)
import AppKit

/// 画面里有什么：照应用自己的无障碍树列出来，页面照它在画面上摆一层看不见的元素（`ScreenPage` 的 `mirror`）。
/// 只读：点与键仍照坐标造事件（`WindowScreen+Input`），这里只多两样照元素做的：给它键盘焦点、换掉输入框里的字。
extension WindowScreen {
  struct Outlined {
    /// 等着答的：`since` 是哪一刻问的。
    var asking: [(since: Double, reply: @Sendable (Data?) -> Void)] = []
    var timer: Timer?
    /// 最近那一份里编号 → 元素。编号跟着元素走：元素还在，下一份里还是这个号，页面那头的元素（连同 Agent 手里的引用）就不换。
    /// `spot`：它看得见的那一块的正中（屏上），页面那头点它也落在这里。
    var elements: [Int: (element: NSObject, spot: CGPoint)] = [:]
    var ids: [AnyHashable: Int] = [:]
    var next = 0
    /// 开始有人看的那一刻：SwiftUI 的无障碍树、头一帧画面都要过一会儿才有，`answer` 等它们。
    var woke = 0.0
  }

  /// SwiftUI 没有辅助技术在场时不建无障碍树（实测：宿主视图底下是空的）；这是旁白这类客户端打开的那个开关，打开后下一轮它就建。
  /// 走老式的接口：新式的协议里没有这一项。
  @MainActor func outlines() {
    outlined.woke = CACurrentMediaTime()
    NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: true, with: "AXEnhancedUserInterface")
  }

  // MARK: 等停下来再答

  /// 画面与输入都停了这么久才答：刚点下去、动画还在走时答出去的是半截的。
  private static let quiet = 0.12
  /// 最多等这么久：一直在动的画面（转圈、视频）也要答。
  private static let patience = 0.6

  @MainActor func ask(_ reply: @escaping @Sendable (Data?) -> Void) {
    outlined.asking.append((CACurrentMediaTime(), reply))
    guard outlined.timer == nil else { return }
    // 排在运行循环的各种模式里：菜单开着、按钮按着时也照样答（同 `onMain`）
    let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.answer() }
    }
    RunLoop.main.add(timer, forMode: .common)
    outlined.timer = timer
  }

  @MainActor private func answer() {
    // 窗口还没开出来（应用刚起）也算没停：答出去的是一张空的
    let now = CACurrentMediaTime(), still = picture != nil && now - max(changed, input.time, outlined.woke) >= Self.quiet
    let due = outlined.asking.filter { still || now - $0.since >= Self.patience }
    guard !due.isEmpty else { return }
    outlined.asking.removeAll { still || now - $0.since >= Self.patience }
    if outlined.asking.isEmpty {
      outlined.timer?.invalidate()
      outlined.timer = nil
    }
    // `points`：画面横着是应用里的多少点。`ms`：走这一遍占了主线程多久，页面照它定画面隔一会儿小动一下时多久再问
    let nodes = nodes()
    let data = try? JSONSerialization.data(withJSONObject: [
      "nodes": nodes, "points": picture.map { $0.window.width / $0.scale } ?? 0, "ms": (CACurrentMediaTime() - now) * 1000,
    ])
    due.forEach { $0.reply(data) }
  }

  // MARK: 走一遍

  /// 一份里最多这么多个元素：再多页面那头摆不动，Agent 也读不完。
  private static let limit = 600

  @MainActor private func nodes() -> [[String: Any]] {
    guard let picture else { return [] }
    var walk = Walk(picture: picture, known: outlined.ids, next: outlined.next)
    let nodes = stack.compactMap { window -> [String: Any]? in
      walk.menu = level(window) == .popUpMenu
      let inner = walk.children(of: window, clip: window.frame, depth: 0)
      // 里面什么都没有的窗不列（系统盖在窗口那三颗钮上的"共享中"标记就是这样一扇）
      guard window === shown || !inner.isEmpty else { return nil }
      var node: [String: Any] = ["i": walk.id(window, seen: window.frame), "r": window === shown ? "window" : walk.menu ? "menu" : "dialog", "b": walk.box(window.frame)]
      if !window.title.isEmpty { node["n"] = window.title }
      // 表单开着时底下那扇窗点不动
      if window.sheetParent != nil || window === NSApp.modalWindow { node["modal"] = true }
      node["k"] = inner
      return node
    }
    outlined.elements = walk.elements
    outlined.ids = walk.ids
    outlined.next = walk.next
    return nodes
  }

  private struct Walk {
    let picture: (all: CGRect, window: CGRect, scale: Double)
    let known: [AnyHashable: Int]
    var next: Int
    var elements: [Int: (element: NSObject, spot: CGPoint)] = [:]
    var ids: [AnyHashable: Int] = [:]
    /// 同一张表里说着同样内容的行见过几条。
    var rows: [AnyHashable: Int] = [:]
    /// 正走在一扇菜单的窗里：它的每一项是表格的一行（实测 macOS 27），列成菜单项。
    var menu = false

    /// `key`：元素每问一次都是新造的那一种（表格的行）凭它认，不给就认对象本身。`seen`：它看得见的那一块。
    mutating func id(_ element: NSObject, key: AnyHashable? = nil, seen: CGRect) -> Int {
      let key = key ?? AnyHashable(ObjectIdentifier(element))
      let id = ids[key] ?? known[key] ?? { next += 1; return next }()
      ids[key] = id
      elements[id] = (element, CGPoint(x: seen.midX, y: seen.midY))
      return id
    }

    /// 表格的行凭它说的内容认，不凭第几行：插了、删了、重排之后同一个位置上是另一条记录，旧编号（Agent 手里的引用）不能落到它头上。
    /// 说着同样内容的几行照先后分。
    private mutating func row(_ name: String, _ kids: [[String: Any]], in parent: NSObject) -> AnyHashable {
      func said(_ nodes: [[String: Any]]) -> String {
        nodes.map { ($0["n"] as? String ?? "") + "\u{1F}" + ($0["v"] as? String ?? "") + said($0["k"] as? [[String: Any]] ?? []) }.joined(separator: "\u{1E}")
      }
      let content = [AnyHashable(ObjectIdentifier(parent)), AnyHashable(name.isEmpty ? said(kids) : name)]
      rows[content, default: 0] += 1
      return AnyHashable(content + [AnyHashable(rows[content] ?? 0)])
    }

    /// 屏上的一块 → 画面里的位置（0…1：左、上、宽、高）。
    func box(_ rect: CGRect) -> [Double] {
      let (x, y) = (picture.scale / picture.window.width, picture.scale / picture.window.height)
      return [(rect.minX - picture.all.minX) * x, (picture.all.maxY - rect.maxY) * y, rect.width * x, rect.height * y].map { ($0 * 10000).rounded() / 10000 }
    }

    /// `clip`：这一层看得见的那一块（窗口，往里是滚动区）。滚出去的元素不列，露出一半的只算露出来的那一半：点它的正中才点得中。
    mutating func children(of parent: NSObject, clip: CGRect, depth: Int) -> [[String: Any]] {
      let role = WindowScreen.text(WindowScreen.read(parent, "accessibilityRole")) ?? ""
      // 表格的行只要看得见的那些：全要的话上万行的表一行行问过去
      let all = (["AXOutline", "AXTable", "AXList"].contains(role) ? WindowScreen.read(parent, "accessibilityVisibleRows") : nil) ?? WindowScreen.read(parent, "accessibilityChildren")
      return NSAccessibility.unignoredChildren(from: all as? [Any] ?? []).flatMap { node($0, in: parent, clip: clip, depth: depth + 1) }
    }

    /// 这个元素的那一条；它自己不值得列（没有名字的分组、滚动区）时是它里面的那些。
    private mutating func node(_ object: Any, in parent: NSObject, clip: CGRect, depth: Int) -> [[String: Any]] {
      // 别的窗（表单、弹层）各自在 `stack` 里列
      guard depth < 40, elements.count < WindowScreen.limit, let element = object as? NSObject, !(element is NSWindow),
            let role = WindowScreen.text(WindowScreen.read(element, "accessibilityRole")), !WindowScreen.dropped.contains(role),
            let frame = WindowScreen.frame(element) else { return [] }
      let seen = frame.intersection(clip)
      guard !seen.isEmpty else { return [] }
      let subrole = WindowScreen.text(WindowScreen.read(element, "accessibilitySubrole")) ?? ""
      guard !WindowScreen.dropped.contains(subrole) else { return [] }
      let kids = WindowScreen.leaves.contains(role) ? [] : children(of: element, clip: role == "AXScrollArea" ? seen : clip, depth: depth)
      let name = WindowScreen.text(WindowScreen.read(element, "accessibilityLabel")) ?? WindowScreen.text(WindowScreen.read(element, "accessibilityTitle")) ?? ""
      // 值只在用得上的那几种上问：SwiftUI 的元素答一次要几百微秒（把字连同字体属性算一遍，实测），是这一遍里最贵的
      let raw = { WindowScreen.read(element, "accessibilityValue") }, value = { WindowScreen.text(raw()) }
      var node: [String: Any] = ["b": box(seen)]
      switch role {
      case "AXStaticText":
        guard let said = value() ?? (name.isEmpty ? nil : name) else { return kids }
        node["r"] = "text"
        node["n"] = said
      case "AXTextField", "AXTextArea", "AXComboBox":
        node["r"] = subrole == "AXSearchField" ? "searchbox" : "textbox"
        if role == "AXTextArea" { node["lines"] = true }
        // 密码框不说里面的字，只说多长（无障碍给的是等长的圆点）：页面那头凭它知道刚填的那段进没进去
        if subrole == "AXSecureTextField" {
          node["secret"] = true
          node["len"] = value()?.utf16.count ?? 0
        } else {
          node["v"] = WindowScreen.text(raw(), limit: WindowScreen.longest) ?? ""
        }
        if let hint = WindowScreen.text(WindowScreen.read(element, "accessibilityPlaceholderValue")) { node["hint"] = hint }
      case "AXCheckBox", "AXRadioButton":
        node["r"] = role == "AXRadioButton" ? "radio" : subrole == "AXSwitch" || subrole == "AXToggle" ? "switch" : "checkbox"
        node["on"] = value() == "1"
      case "AXDisclosureTriangle":
        node["r"] = "button"
        node["open"] = value() == "1"
      default:
        guard let known = WindowScreen.roles[role] else {
          // 没有名字的分组、不认识的：不单列，里面的照样列；有名字的分组留着（Agent 靠它分得清两处同名的钮）
          guard role == "AXGroup", !name.isEmpty, !kids.isEmpty else { return kids }
          node["r"] = "group"
          break
        }
        node["r"] = menu && role == "AXRow" ? "menuitem" : known
        if ["combobox", "slider", "spinbutton"].contains(known) { node["v"] = value() ?? "" }
        // 说不出是什么的图、菜单里的分隔线：不列
        if known == "img" || known == "menuitem", name.isEmpty { return kids }
      }
      if node["n"] == nil, !name.isEmpty { node["n"] = name }
      // 多行的文本区后台时自称不可用（实测），不信它
      if role != "AXTextArea", WindowScreen.read(element, "accessibilityEnabled", "isAccessibilityEnabled") as? Bool == false { node["off"] = true }
      if WindowScreen.read(element, "accessibilityFocused", "isAccessibilityFocused") as? Bool == true { node["focus"] = true }
      if WindowScreen.read(element, "accessibilitySelected", "isAccessibilitySelected") as? Bool == true { node["sel"] = true }
      if !kids.isEmpty { node["k"] = kids }
      node["i"] = id(element, key: role == "AXRow" ? row(name, kids, in: parent) : nil, seen: seen)
      return [node]
    }
  }

  /// 无障碍的角色 → 页面上用的角色（ARIA 的叫法，Agent 的快照里就是这个词）。没列的不单列。
  private static let roles = [
    "AXButton": "button", "AXMenuButton": "button", "AXColorWell": "button", "AXPopUpButton": "combobox", "AXSlider": "slider", "AXIncrementor": "spinbutton",
    "AXLink": "link", "AXImage": "img", "AXHeading": "heading", "AXRow": "option", "AXOutline": "list", "AXTable": "list", "AXList": "list",
    "AXTabGroup": "tablist", "AXRadioGroup": "radiogroup", "AXToolbar": "toolbar", "AXMenu": "menu", "AXMenuItem": "menuitem",
    "AXProgressIndicator": "progressbar", "AXBusyIndicator": "progressbar", "AXLevelIndicator": "progressbar",
  ]
  /// 连同里面的都不列：滚动条、表格的列（内容在行里已有一份）、窗口自己的那三颗钮（按窗口取的画面里它们被系统的"共享中"标记盖着）。
  private static let dropped: Set = [
    "AXScrollBar", "AXColumn", "AXGrowArea", "AXSplitter", "AXMenuBar", "AXValueIndicator", "AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton",
  ]
  /// 不往里走的：里面是它自己的零件。
  private static let leaves: Set = ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXPopUpButton", "AXButton", "AXCheckBox", "AXRadioButton", "AXImage"]

  // MARK: 问元素

  /// 老式的属性名：只答 `accessibilityAttributeValue:` 的元素（表格的行）用。
  private static let legacy = [
    "accessibilityRole": "AXRole", "accessibilitySubrole": "AXSubrole", "accessibilityChildren": "AXChildren", "accessibilityTitle": "AXTitle",
    "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue", "accessibilityEnabled": "AXEnabled", "accessibilitySelected": "AXSelected",
    "accessibilityFocused": "AXFocused",
  ]
  private static let legacyRead = NSSelectorFromString("accessibilityAttributeValue:")

  /// 无障碍的元素不一定声明了协议（SwiftUI 的、表格的行）：照方法名问，答不了的是 nil。
  fileprivate static func read(_ element: NSObject, _ key: String, _ getter: String? = nil) -> Any? {
    if element.responds(to: NSSelectorFromString(getter ?? key)) { return element.value(forKey: key) }
    guard let name = legacy[key], element.responds(to: legacyRead) else { return nil }
    return element.perform(legacyRead, with: name)?.takeUnretainedValue()
  }

  fileprivate static func text(_ value: Any?, limit: Int = 400) -> String? {
    let text: String? = switch value {
    case let text as String: text
    case let text as NSAttributedString: text.string
    case let number as NSNumber: number.stringValue
    default: nil
    }
    return text.flatMap { $0.isEmpty ? nil : String($0.prefix(limit)) }
  }

  /// 输入框里的字最多说这么长（名字、文字是 400）：`fill` 之后页面那头凭它核对填没填进去，再长的核对不了。
  fileprivate static let longest = 10000

  /// 元素在屏上的位置（AppKit 的坐标）。老式的那一种在进程里问到的也是左下原点的（翻成左上原点是给进程外的客户端做的，实测）。
  fileprivate static func frame(_ element: NSObject) -> CGRect? {
    if let frame = (read(element, "accessibilityFrame") as? NSValue)?.rectValue { return frame }
    guard element.responds(to: legacyRead), let origin = (element.perform(legacyRead, with: "AXPosition")?.takeUnretainedValue() as? NSValue)?.pointValue,
          let size = (element.perform(legacyRead, with: "AXSize")?.takeUnretainedValue() as? NSValue)?.sizeValue else { return nil }
    return CGRect(origin: origin, size: size)
  }

  // MARK: 照元素做

  /// 照点它一下会带来的做，不点下去：这一点下的视图拿第一响应者。无障碍那条给焦点的路不用：SwiftUI 的输入框从 AppKit 的框那边接不住（实测，问它还说没聚焦）。
  @MainActor func focus(_ id: Int) {
    guard let spot = outlined.elements[id]?.spot, let window = window(at: spot) else { return }
    let before = window.firstResponder
    if let view = window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: spot)), view.acceptsFirstResponder { window.makeFirstResponder(view) }
    // 输入框刚拿到焦点时是全选的，接着按的字会把原来的换掉：光标放到末尾，同网页里聚焦一个框
    if window.firstResponder !== before, let field = window.firstResponder as? NSText { field.selectedRange = NSRange(location: field.string.utf16.count, length: 0) }
    // 键盘跟到它所在的那扇窗，同点了它一下
    input.focus = window
    input.around = Set(stack.map(\.windowNumber))
  }

  @MainActor func fill(_ id: Int, _ text: String) {
    focus(id)
    // 它没接住焦点（停用的框）就不填：不然字落进原先拿着键盘的另一个框里
    guard let element = outlined.elements[id]?.element, Self.read(element, "accessibilityFocused", "isAccessibilityFocused") as? Bool == true,
          let field = typing?.firstResponder as? NSText else { return }
    field.selectAll(nil)
    text.isEmpty ? field.delete(nil) : insert(text)
  }
}
#endif
