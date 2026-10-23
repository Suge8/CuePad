import CueStore
import SwiftUI

extension View {
    #if os(macOS)
    /// 单次交互（`-CuePadBench interact`）时记下这条任务行在窗口里的位置，前台量的"任务气泡开"用真实点击点它（`InteractionBench`）；平时什么都不挂。
    @ViewBuilder func benchSpot(_ task: UUID) -> some View {
        #if DEBUG
        if InteractionBench.locatesRows {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { InteractionBench.rows[task] = $0 }
        } else {
            self
        }
        #else
        self
        #endif
    }
    #endif

    #if os(iOS)
    /// 点 Cue 页头开合面板的那条路交给测量（`IOSInteractionBench` 的"开合 Cue 面板"）。
    func debugExposesCuePanel(_ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onAppear { DebugScene.toggleCuePanel = toggle }
        #else
        self
        #endif
    }

    /// 展开底部"⋯"的那条路交给调试画面（`-CuePadPlacesOpen`、`dockTourIfAsked`），状态在窄屏的容器里（`DockRoot`）。
    func debugExposesPlaces(_ open: @escaping () -> Void) -> some View {
        #if DEBUG
        onAppear { DebugScene.openPlaces = open }
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
            opened.wrappedValue = items.lazy.flatMap { entry in entry.previews.map { PreviewOpening(preview: $0, batch: entry.previews, group: entry.id.uuidString, reply: .session(session)) } }
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
    /// 主窗口根上：按启动参数摆好调试画面、挂上自检用的布局环，摆好后报"首帧就绪"（`xc.sh shot` 等它再截图）。
    func debugScene(_ workspace: Workspace) -> some View {
        #if DEBUG
        task {
            await DebugScene.prepare(workspace)
            await DebugScene.signalReady(workspace.services)
            // 接力与关窗不挂在窗口内容上：关窗时内容摘下（`MainShellWindow`），内容上的任务跟着停
            Task { await DebugScene.wakeIfAsked(workspace) }
            Task {
                let from = workspace.root
                await DebugScene.saysIfAsked(workspace.services, visit: { workspace.show(.cue) }, back: { workspace.show(from) })
            }
            Task { await DebugScene.awayIfAsked(workspace.services.store) }
            Task { await DebugScene.relayIfAsked(workspace) }
            Task { await DebugScene.closeIfAsked(workspace) }
            Task { await DebugScene.openMenuIfAsked() }
            Task { await DebugScene.cueFlowIfAsked(workspace) }
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
                DebugScene.noticeIfAsked(workspace)
                await DebugScene.signalReady(workspace.services)
                async let wakes: Void = DebugScene.wakeIfAsked(workspace)
                let from = (workspace.root, workspace.path)
                async let says: Void = DebugScene.saysIfAsked(
                    workspace.services, visit: { workspace.select(.cue) }, back: {
                        workspace.select(from.0)
                        workspace.path = from.1
                    })
                async let relays: Void = DebugScene.relayIfAsked(workspace)
                async let flow: Void = DebugScene.cueFlowIfAsked(workspace)
                async let away: Void = DebugScene.awayIfAsked(
                    workspace.services.store, leave: { workspace.show(.progress) }, back: { workspace.show(.cue) })
                async let tour: Void = DebugScene.dockTourIfAsked(workspace)
                async let cueNow: Void = DebugScene.cueNowTourIfAsked(workspace.cue)
                await DebugScene.cycleIfAsked(workspace.services)
                _ = await (wakes, says, relays, flow, away, tour, cueNow)
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
/// 主窗口的内容：截图只截主窗口，调试画面要拍的另一扇窗（菜单栏面板、项目表单、新会话）放进主窗口里拍；其余是 `main`。
struct DebugStage<Main: View>: View {
    let workspace: Workspace
    @ViewBuilder let main: () -> Main

    var body: some View {
        #if DEBUG
        switch DebugScene.scene {
        case "menubar": DebugMenuBarStage().environment(workspace)
        case "cuebar": DebugMenuBarStage(cueBar: true).environment(workspace)
        case "projectform": ProjectForm(ProjectFormRequest()).environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        case "newsession": DebugNewSessionForm().environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
        default: main()
        }
        #else
        main()
        #endif
    }
}
#endif
