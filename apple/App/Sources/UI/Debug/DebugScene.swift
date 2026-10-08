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
/// - `-CuePadScene <画面>`：初始画面。Mac：collapsed、older、editor、task（整页打开本项目第一条任务）、search、tasks、trash、settings、menubar、projectform；
///   agent 打开 Agent 整页列表，session 整页打开 `-CuePadSession <会话名>`（这两个画面配 `-CuePadDemo YES` 时写入 Mac 同步来的演示会话，见 `DebugScene+PiDemo.swift`）；
///   iOS 见 `DebugScene+iOS.swift`；
/// - `-CuePadSearch <关键词>`：search 画面的预填关键词；`-CuePadCard <正文开头>`：editor 画面打开哪张卡；`-CuePadSelect <起点:长度>`：编辑器载入后选中这一段（看选区操作）；
/// - `-CuePadWindowSize 1280x800`（仅 Mac）：主窗口尺寸（内容铺满标题栏，即整窗尺寸）；`-CuePadSidebar hidden`（仅 Mac）：任何画面都先收起侧栏；
/// - `-CuePadBench <sidebar|motion|resize|churn|perf|press>`（仅 Mac；perf 见 `PerfBench`，press 配 `-CuePadPressAt x,y` 连拍按压）：开合侧栏 10 次 / 存卡后开合纸页（都在结束后退出，给 Instruments 或连拍取帧）；
///   resize 在侧栏开合途中拉窄窗口后停住，给截图核对页宽；churn 边加卡边逐点拉宽窗口，查布局反馈环（结束后退出）；
/// - `-CuePadOffscreen YES`（仅 Mac）：主窗口放在所有屏幕之外（第一次显示前就放好、不被系统夹回，也不记位置），复现窗口不可见时的布局、测量时不露在桌面上；
/// - `-CuePadImport <cuepad.db 路径>`（仅 Mac）：界面起来后导入一份旧版资料库，复现首次启动边导边变；
/// - `-CuePadGeometryLoop YES`（仅 Mac）：挂一个刻意的几何回写环，给布局压力场景的检测器自检；
/// - `-CuePadShowsDone YES`（仅 iOS）：任务页的"最近完成"默认展开并滚到底；
/// - `-CuePadCatalogFailure YES`：项目目录读取直接报错（重试也一样），核对读取失败画面；
///   `-CuePadCatalogFailure once`：每个窗口（含菜单栏面板）只有第一次读取报错，按"重试"后恢复，核对重试路径。
/// 设置项可在参数域覆盖：`-theme dark`；Mac 隔离 Pi 目录下隐藏"连接 Pi"提示：`-piExtensionDeclined YES`。
@MainActor
enum DebugScene {
    static var defaults: UserDefaults { .standard }
    static var scene: String? { defaults.string(forKey: "CuePadScene") }
    static var searchText: String { defaults.string(forKey: "CuePadSearch") ?? "" }
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
        workspace.show(.project(project.id))
        return project.id
    }

    /// `-CuePadComposer <cards|attachments|lines>`（配 session、newsession 画面，iOS 与 Mac）：输入框出现时 cards 打开选卡片面板，
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
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
    }
}
#endif
