import CueStore
import SwiftUI

extension View {
    /// 单次交互（`-CuePadBench interact`，仅 Mac）时记下这一行在窗口里的位置（左上为原点，`.global` 在 Mac 上就是窗口），只记看得见的那一页上的（`pageActive`；
    /// 藏起的页与预热的页还在视图树里、照样排版），离屏、页藏起时撤掉（`InteractionBench.rows`）：
    /// 前台量的"任务气泡开"用真实点击点任务行；宽屏跨阈值认中段读的那一条（看板卡、对话里的一条，`WidePage`）。平时什么都不挂。
    @ViewBuilder func benchSpot(_ id: some Hashable) -> some View {
        #if os(macOS) && DEBUG
        if InteractionBench.locatesRows { modifier(BenchSpot(id: id)) } else { self }
        #else
        self
        #endif
    }

    #if os(iOS)
    /// 点 Cue 页头开合面板的那条路交给测量（`IOSInteractionBench` 的"开合 Cue 面板"）。
    func debugExposesCuePanel(_ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onAppear { DebugScene.toggleCuePanel = toggle }
        #else
        self
        #endif
    }

    #endif

    /// 项目页任务纸点"还有 N 条"的那条路交给测量（两端 `InteractionBench` 的"展开任务"）：看得见的那一页（`active`）的纸。
    func debugExposesTaskFold(active: Bool = true, _ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onChange(of: active, initial: true) { if active { DebugScene.toggleTaskFold = toggle } }
        #else
        self
        #endif
    }

    /// 会话页直接打开 `-CuePadOpenPreview <标题或文件名>` 那张预览（对话里的交付物到了再找）。
    func debugOpensPreview(in items: [PiChatEntry], session: PiSessionState, _ opened: Binding<PreviewOpening?>) -> some View {
        #if DEBUG
        task(id: items.count) {
            guard let title = DebugScene.defaults.string(forKey: "CuePadOpenPreview") else { return }
            opened.wrappedValue = items.lazy.flatMap { entry in entry.previews.map { PreviewOpening(preview: $0, batch: entry.previews, group: entry.id.uuidString) } }
                .first { $0.preview.title == title || $0.preview.name == title }
        }
        #else
        self
        #endif
    }

    #if os(iOS)
    /// `-CuePadCompact <宽>`：按这么宽的窄窗口画（模拟器开不了分屏）。
    @ViewBuilder func debugCompact() -> some View {
        #if DEBUG
        let width = DebugScene.defaults.double(forKey: "CuePadCompact")
        if width > 0 {
            environment(\.horizontalSizeClass, .compact).frame(width: width).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self
        }
        #else
        self
        #endif
    }
    #endif

    /// 这一处正在过渡（如编辑页正在淡入）：截图的就绪标记等它停下。SwiftUI 自己驱动的动画在图层上看不出来，由视图自己报。
    func debugSettling(_ busy: Bool) -> some View {
        #if DEBUG
        modifier(DebugSettling(busy: busy))
        #else
        self
        #endif
    }

    /// `older` 画面：墙排好（`ready`）后滚到"更早"。
    func debugScrollsToOlder(_ proxy: ScrollViewProxy, ready: Bool) -> some View {
        #if DEBUG
        onChange(of: ready) { if ready { DebugScene.scrollIfNeeded(proxy) } }
        #else
        self
        #endif
    }

    #if os(macOS)
    /// 主窗口根上：按启动参数摆好调试画面（状态图形总览盖在最上层）、挂上自检用的布局环，摆好后报"首帧就绪"（`xc.sh shot` 等它再截图）。
    func debugScene(_ workspace: Workspace) -> some View {
        #if DEBUG
        overlay {
            if DebugScene.scene == "stateicons" { StateGlyphSheet().withPalette() }
            if DebugScene.scene == "rail" { DebugSessionRail(workspace: workspace).modifier(PaletteProvider()) }
        }
        .task {
            await DebugScene.prepare(workspace)
            await DebugScene.seedRailIfAsked(workspace.services)
            await DebugScene.projectFormIfAsked(workspace)
            await DebugScene.signalReady(workspace.services)
            // 接力与关窗不挂在窗口内容上：关窗时内容摘下（`MainShellWindow`），内容上的任务跟着停
            Task { await DebugScene.wakeIfAsked(workspace) }
            Task { await DebugScene.noticeIfAsked(workspace) }
            Task { await DebugScene.composerNoticeIfAsked(workspace.services) }
            Task { await DebugScene.replyBlinkIfAsked(workspace.services.store) }
            Task {
                let from = workspace.mainRoute
                await DebugScene.saysIfAsked(workspace.services, visit: { workspace.show(.cue) }, back: { workspace.show(from) })
            }
            Task { await DebugScene.awayIfAsked(workspace.services.store) }
            Task { await DebugScene.relayIfAsked(workspace) }
            Task { await DebugScene.closeIfAsked(workspace) }
            Task { await DebugScene.openMenuIfAsked() }
            Task { await DebugScene.cueFlowIfAsked(workspace) }
            Task { await DebugScene.boardTourIfAsked(workspace.services.store) }
            await DebugScene.cycleIfAsked(workspace.services)
        }
        .background { if DebugScene.injectsGeometryLoop { GeometryLoopProbe() } }
        #else
        self
        #endif
    }
    #endif

    #if os(iOS)
    /// 窗口根上：按启动参数摆好调试画面（样板页盖在最上层），摆好后报"首帧就绪"（`xc.sh shot` 等它再截图）。
    func debugScene(_ workspace: Workspace) -> some View {
        #if DEBUG
        overlay {
            // 盖在根上（在注入配色的那层外面），自己按外观取配色
            Group {
                switch DebugScene.scene {
                case "style": StyleBoard()
                case "icons": IconSheet()
                case "stateicons": StateGlyphSheet()
                case "rail": DebugSessionRail(workspace: workspace).modifier(PaletteProvider())
                case "widgets": DebugWidgetStage()
                case "activity": DebugActivityStage(workspace: workspace)
                case "share": DebugShareStage(location: workspace.services.location)
                default: EmptyView()
                }
            }
            .withPalette()
        }
            .task {
                await DebugScene.prepare(workspace)
                await DebugScene.seedRailIfAsked(workspace.services)
                await DebugScene.signalReady(workspace.services)
                async let notice: Void = DebugScene.noticeIfAsked(workspace)
                async let notices: Void = DebugScene.composerNoticeIfAsked(workspace.services)
                async let wakes: Void = DebugScene.wakeIfAsked(workspace)
                async let blinks: Void = DebugScene.replyBlinkIfAsked(workspace.services.store)
                let from = (workspace.mainRoute, workspace.path)
                async let says: Void = DebugScene.saysIfAsked(
                    workspace.services, visit: { workspace.select(.cue) }, back: {
                        workspace.select(from.0)
                        workspace.path = from.1
                    })
                async let relays: Void = DebugScene.relayIfAsked(workspace)
                async let flow: Void = DebugScene.cueFlowIfAsked(workspace)
                async let away: Void = DebugScene.awayIfAsked(
                    workspace.services.store, leave: { workspace.show(.progress) }, back: { workspace.show(.cue) })
                async let cueNow: Void = DebugScene.cueNowTourIfAsked(workspace)
                async let board: Void = DebugScene.boardTourIfAsked(workspace.services.store)
                await DebugScene.cycleIfAsked(workspace.services)
                _ = await (notice, notices, wakes, blinks, says, relays, flow, away, cueNow, board)
            }
        #else
        self
        #endif
    }
    #endif
}

#if DEBUG
private struct DebugSettling: ViewModifier {
    let busy: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: busy, initial: true) { DebugScene.settling(id, busy) }
            .onDisappear { DebugScene.settling(id, false) }
    }
}
#endif

#if os(macOS)
/// 主窗口的内容：截图只截主窗口，调试画面要拍的另一扇窗（菜单栏面板、新会话）放进主窗口里拍；其余是 `main`。
struct DebugStage<Main: View>: View {
    let workspace: Workspace
    @ViewBuilder let main: () -> Main

    var body: some View {
        #if DEBUG
        switch DebugScene.scene {
        case "menubar": DebugMenuBarStage().environment(workspace)
        case "cuebar": DebugMenuBarStage(cueBar: true).environment(workspace)
        case "newsession": DebugNewSessionForm().environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        default: main()
        }
        #else
        main()
        #endif
    }
}
#endif

#if os(macOS) && DEBUG
private extension DebugScene {
    /// `projectform` 画面：项目表单经浮层弹出（同真用时，压暗的窗口上居中一块），给了 `-CuePadProject` 是编辑它（项目页垫在下面），否则新建。
    static func projectFormIfAsked(_ workspace: Workspace) async {
        guard scene == "projectform" else { return }
        await running("项目表单") {
            // 主区开着哪个项目不算（启动就停在上次的项目页），只认参数打开的（`prepareLibrary` 已打开它）
            let asked = defaults.string(forKey: "CuePadProject") == nil ? nil : workspace.currentProject
            let existing = if let asked { try await workspace.services.store.project(asked) } else { Project?.none }
            workspace.projectForm = .init(project: existing)
        }
    }
}

private struct BenchSpot<ID: Hashable>: ViewModifier {
    let id: ID
    @Environment(\.pageActive) private var active
    /// 最近一次的位置：页重新露出来时位置可能没变、不再报，从这里补登记。是引用，写它不触发更新。
    @State private var last = Last()

    final class Last { var frame: CGRect? }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                last.frame = frame
                if active { InteractionBench.rows[id] = frame }
            }
            .onChange(of: active, initial: true) { InteractionBench.rows[id] = active ? last.frame : nil }
            .onDisappear { InteractionBench.rows[id] = nil }
    }
}
#endif
