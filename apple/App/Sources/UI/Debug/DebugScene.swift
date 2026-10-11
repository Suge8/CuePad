import CueStore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 滚动定位锚点。
enum ScrollAnchor {
    static let older = "older"
}

#if DEBUG
/// 视觉验收用的启动参数（只在 Debug 构建读取，配合 `CUEPAD_LIBRARY_DIR` 使用隔离资料库）：
/// - `-CuePadDemo YES`：库为空时写入演示数据；
/// - `-CuePadSeed perf`（仅 Mac）：库为空时写入性能测量用的大资料库（`PerfLibrary`），配合 `-CuePadBench perf`；
/// - `-CuePadProject <名称>`：打开该项目；
/// - `-CuePadScene <画面>`：初始画面。Mac：collapsed、older、editor、attach（editor 再弹出"挂到任务"面板）、task（整页打开本项目第一条任务）、search、tasks、trash、archive、settings、menubar、projectform；
///   agent 打开 Agent 整页列表，agentfirst 等空闲时先挂上的 Agent 页读完一份后改数据（新会话、atlas 出错）、改窗口为 1100x720 再点开，session 整页打开 `-CuePadSession <会话名>`（这两个画面配 `-CuePadDemo YES` 时写入 Mac 同步来的演示会话，见 `DebugScene+PiDemo.swift`）；
///   iOS 见 `DebugScene+iOS.swift`；
/// - `-CuePadSearch <关键词>`：search 画面的预填关键词；`-CuePadCard <正文开头>`：editor 画面打开哪张卡；`-CuePadSelect <起点:长度>`：编辑器载入后选中这一段（看选区操作）；
/// - `-CuePadWindowSize 1280x800`（仅 Mac）：主窗口尺寸（内容铺满标题栏，即整窗尺寸）；`-CuePadSidebar hidden`（仅 Mac）：任何画面都先收起侧栏；
/// - `-CuePadBench <sidebar|motion|resize|churn|perf|agent|switch|scenarios|interact|press>`（仅 Mac；perf、agent（Agent 整页一路滚到底）见 `PerfBench`，interact（单次交互的点击回合与掉帧，与交互预算比较）见 `InteractionBench`，switch（切会话的耗时与对话区是否空白）见 `SwitchBench`，scenarios（侧栏切项目、会话页滚动与流式、回复框打字、悬停、缩放窗口、⌘K 逐字打，按场景切信号标记）见 `ScenarioBench`，press 配 `-CuePadPressAt x,y` 连拍按压）：开合侧栏 10 次 / 存卡后开合编辑页（都在结束后退出，给 Instruments 或连拍取帧）；
///   resize 在侧栏开合途中拉窄窗口后停住，给截图核对页宽；churn 边加卡边逐点拉宽窗口，查布局反馈环（结束后退出）；
/// - `-CuePadScenario a,b`（仅 Mac，配 `-CuePadBench scenarios`）：只跑列出的场景，名字见 `ScenarioBench`；`-CuePadWheel trackpad`：压测里的滚轮事件带触控板的手势阶段（默认是没有阶段的普通滚轮）；
/// - `-CuePadOffscreen YES`（仅 Mac）：主窗口放在所有屏幕之外（第一次显示前就放好、不被系统夹回，也不记位置），复现窗口不可见时的布局、测量时不露在桌面上；
/// - `-CuePadGeometryLoop YES`（仅 Mac）：挂一个刻意的几何回写环，给布局压力场景的检测器自检；
/// - `-CuePadToolsOpen YES`：会话页每一轮回答上方的工具清单一开始就展开（`ToolActivityLine`）；
/// - `-CuePadShowsDone YES`（仅 iOS）：任务页的"最近完成"默认展开并滚到底；
/// - `-CuePadExplain YES`（仅 iOS）：推入页顶栏有说明时（会话需要 /reload）直接弹出，核对点标题的说明；
/// - `-CuePadCatalogFailure YES`：项目目录读取直接报错（重试也一样），核对读取失败画面；
///   `-CuePadCatalogFailure once`：每个窗口（含菜单栏面板）只有第一次读取报错，按"重试"后恢复，核对重试路径。
/// 设置项可在参数域覆盖：`-theme dark`；Mac 隔离 Pi 目录下隐藏"连接 Pi"提示：`-piExtensionDeclined YES`。
@MainActor
enum DebugScene {
    static var defaults: UserDefaults { .standard }
    static var scene: String? { defaults.string(forKey: "CuePadScene") }
    /// 压测按关键词换搜索词时写这里，只在内存里：写进 `UserDefaults.standard` 会落进真实偏好域，之后每个 Debug 实例的 ⌘K 都预填它。
    static var searchOverride: String?
    /// 搜索框预填的字：压测换的词，否则只认启动参数（参数域），不读已存的偏好。
    static var searchText: String {
        searchOverride ?? (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["CuePadSearch"] as? String) ?? ""
    }
    /// Mac session 画面要打开的会话（演示会话的 sessionID 与会话名相同）。
    static var sessionToOpen: String? { scene == "session" ? defaults.string(forKey: "CuePadSession") : nil }
    /// 截图演示：编辑器载入后选中这一段（`起点:长度`，UTF-16）。
    static var editorSelection: NSRange? {
        guard let parts = defaults.string(forKey: "CuePadSelect")?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 else { return nil }
        return NSRange(location: parts[0], length: parts[1])
    }
    /// 挂上刻意的几何回写环（只给布局压力场景的检测器自检用）。
    static var injectsGeometryLoop: Bool { defaults.bool(forKey: "CuePadGeometryLoop") }

    /// 第 `attempt` 次订阅项目目录（`Workspace.catalogAttempt`，从 0 起）是否按 `-CuePadCatalogFailure` 注入失败。
    static func injectCatalogFailure(attempt: Int) throws {
        let fails = defaults.string(forKey: "CuePadCatalogFailure") == "once" ? attempt == 0 : defaults.bool(forKey: "CuePadCatalogFailure")
        if fails { throw InjectedFailure() }
    }

    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "调试注入的读取失败（-CuePadCatalogFailure）" }
    }

    /// 需要时写入演示数据，并按参数选中项目；返回选中的项目。
    static func prepareLibrary(_ workspace: Workspace) async -> UUID? {
        let store = workspace.services.store
        // -CuePadSampleCrash YES：存一份样例崩溃诊断，设置里出现"上次崩溃"（配 -CuePadCrashSheet YES 直接打开摘要）
        if defaults.bool(forKey: "CuePadSampleCrash") { workspace.services.diagnostics.record([sampleCrash]) }
        #if os(macOS)
        if defaults.string(forKey: "CuePadSeed") == "perf", (try? await store.projects().isEmpty) == true {
            do { try await PerfLibrary.seed(store) } catch { workspace.fail(error) }
        }
        #endif
        if defaults.bool(forKey: "CuePadDemo"), (try? await store.projects().isEmpty) == true {
            do { try await DemoLibrary.seed(store) } catch { workspace.fail(error) }
        }
        guard let name = defaults.string(forKey: "CuePadProject"),
              let project = try? await store.projects().first(where: { $0.name == name })
        else { return nil }
        #if os(macOS)
        workspace.show(.project(project.id))
        #endif
        return project.id
    }

    /// `-CuePadComposer <cards|attachments|lines|slash>`（配 session、newsession 画面，iOS 与 Mac）：输入框出现时 cards 打开选卡片面板，slash 写进 "/re" 弹出斜杠命令面板，
    /// attachments 带上一张卡片（`-CuePadCard` 挑哪张）并放进两张演示图片，lines 写进 9 行文字（看文字区长到 6 行后在里面滚）。
    /// ＋ 菜单是系统菜单、不能代为展开：截图时按一下 ＋（iPhone 17 Pro 回复框：`axe touch -x 37 -y 810 --down --up --delay 0.15`；axe 的 tap 太快，菜单不开）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        switch defaults.string(forKey: "CuePadComposer") {
        case "cards":
            // 等推入页面的转场走完再弹，转场中弹出的面板会被系统丢掉
            try? await Task.sleep(for: .seconds(1))
            source.wrappedValue = .cards
        case "attachments":
            // 先挑未分类里的，没有再挑第一个项目里的
            var id = await card(in: nil, store: store)
            if id == nil, let project = try? await store.projects().first { id = await card(in: project.id, store: store) }
            if let id, let card = try? await store.card(id) {
                draft.wrappedValue.attach(card)
            }
            draft.wrappedValue.images = [(0.85, 0.47, 0.29), (0.25, 0.56, 0.72)].map { PickedImage(data: swatch(red: $0.0, green: $0.1, blue: $0.2)) }
        case "lines":
            draft.wrappedValue.text = (1...9).map { "第 \($0) 行" }.joined(separator: "\n")
        case "slash":
            draft.wrappedValue.text = "/re"
        default:
            break
        }
    }

    /// 一块纯色的 PNG（演示图片）。
    private static func swatch(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let size = CGSize(width: 240, height: 180)
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// `-CuePadCard` 指定（或最近修改）的一张卡。
    static func card(in project: UUID?, store: CueStore) async -> UUID? {
        let cards = (try? await store.cards(in: project)) ?? []
        let prefix = defaults.string(forKey: "CuePadCard") ?? ""
        return cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        later(.milliseconds(300)) { proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35)) }
    }

    /// 产品视图读的启动预设（`DebugHooks.preset`）。
    static var preset: DebugHooks.Preset {
        var preset = DebugHooks.Preset()
        preset.searchText = searchText
        preset.editorSelection = editorSelection
        preset.toolsOpen = defaults.bool(forKey: "CuePadToolsOpen")
        preset.explain = defaults.bool(forKey: "CuePadExplain")
        preset.openPreview = defaults.string(forKey: "CuePadOpenPreview")
        preset.crashSheet = defaults.bool(forKey: "CuePadCrashSheet")
        preset.demoMac = defaults.bool(forKey: "CuePadDemoMac")
        #if os(iOS)
        preset.showsDone = defaults.bool(forKey: "CuePadShowsDone")
        preset.alertStatus = alertStatus
        if scene == "search" { preset.focusedSearch = defaults.string(forKey: "CuePadProject") == nil ? .shelf : .project }
        if scene == "agent" {
            preset.agentQuery = searchText
            preset.agentFromBottom = defaults.integer(forKey: "CuePadHistory") > 0 && searchText.isEmpty
        }
        #endif
        return preset
    }

    // MARK: 截图的首帧就绪

    /// 还没做完的摆画面的事（`later`）。
    private static var pending = 0
    /// 正在过渡的视图（`debugSettling`）。
    private static var unsettled: Set<UUID> = []

    static func settling(_ id: UUID, _ busy: Bool) {
        if busy { unsettled.insert(id) } else { unsettled.remove(id) }
    }

    static func later(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        pending += 1
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
            pending -= 1
        }
    }

    /// `CUEPAD_SHOT_READY` 给了文件路径时，画面摆好（`prepare` 做完）之后等到：读库的结果都回来了、摆画面的事都做完了、
    /// 没有视图报着正在过渡、屏上没有进行中的一次性动画（转圈这类一直循环的不算），连着三帧都这样，再写下这个文件。`xc.sh shot` 等它出现才截图，不靠固定的等待。
    static func signalReady(_ store: CueStore) async {
        guard let path = ProcessInfo.processInfo.environment["CUEPAD_SHOT_READY"] else { return }
        var still = 0
        while still < 3 {
            // 排在页面已经发出的读库之后：它回来时，那些读取也都回来了
            _ = try? await store.projects()
            await nextFrame()
            still = pending == 0 && unsettled.isEmpty && !animating ? still + 1 : 0
        }
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    private static let longestOneShot: CFTimeInterval = 5

    /// 屏上的窗口里有没有一次性的动画在跑（推入、弹出浮窗这类）；一直循环的（转圈、流光）不算。
    private static var animating: Bool {
        func busy(_ layer: CALayer) -> Bool {
            // 看不见的不算（没在刷新的下拉刷新圈也一直在转）
            guard !layer.isHidden, layer.opacity > 0 else { return false }
            let finite = (layer.animationKeys() ?? []).contains { key in
                guard let animation = layer.animation(forKey: key) else { return false }
                // 一次性的：总时长不过几秒。循环的（光标闪烁、转圈、玻璃的跟随）重复次数或时长是极大值，不等它们
                let total = animation.repeatDuration > 0 ? animation.repeatDuration : animation.duration * Double(max(animation.repeatCount, 1))
                return total.isFinite && total <= Self.longestOneShot
            }
            return finite || (layer.sublayers ?? []).contains(where: busy)
        }
        #if os(macOS)
        return NSApp.windows.filter(\.isVisible).compactMap(\.contentView?.superview?.layer).contains(where: busy)
        #else
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.map(\.layer).contains(where: busy)
        #endif
    }

    private static func nextFrame() async {
        #if os(macOS)
        await NextFrame.wait()
        #else
        await withCheckedContinuation { continuation in
            let tick = FrameTick(continuation)
            CADisplayLink(target: tick, selector: #selector(FrameTick.fire)).add(to: .main, forMode: .common)
        }
        #endif
    }
}

#if os(iOS)
private final class FrameTick: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    @objc func fire(_ link: CADisplayLink) {
        link.invalidate()
        continuation?.resume()
        continuation = nil
    }
}
#endif
#endif
