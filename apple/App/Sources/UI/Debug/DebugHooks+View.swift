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

    func debugExposesCuePanel(_ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onAppear { if DebugHooks.scripted { DebugScene.toggleCuePanel = toggle } }
        #else
        self
        #endif
    }

    #if os(iOS)
    func debugExposesQuota(_ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onAppear { if DebugHooks.scripted { DebugScene.toggleQuota = toggle } }
        #else
        self
        #endif
    }

    func debugExposesModals(_ host: ModalHost) -> some View {
        #if DEBUG
        onAppear { DebugScene.modals = host }
        #else
        self
        #endif
    }
    #endif

    #if os(iOS)
    /// 会话页顶那一排的让开（`ChatFollow.showsHeader`）：`-CuePadHeaderHidden YES` 就绪前当作已滑去看历史（整排让开，拍截图）；
    /// `-CuePadHeaderCycle YES`（配录屏）就绪后来回走：滑去看历史（让开）→ 点顶上唤出 → 再滑（让开）→ 回到最新（回来），每步 1.5 秒。
    /// 走的是滚动区报读数与点顶部时调的同一些 `ChatFollow` 方法，滚动位置本身不动。
    func debugDrivesHeader(_ follow: Binding<ChatFollow>) -> some View {
        #if DEBUG
        onAppear {
            let away: @MainActor () -> Void = { follow.wrappedValue.scrolled(atNewest: false, beyondScreen: false, nearOldest: false, byUser: true) }
            if DebugScene.args.layoutOpts.headerHidden { DebugScene.later(.seconds(1), away) }
            guard DebugScene.args.layoutOpts.headerCycle else { return }
            Task {
                await Task.wait(for: .seconds(3))
                let steps: [@MainActor () -> Void] = [away, { follow.wrappedValue.reveal() }, away, { follow.wrappedValue.jumpToNewest() }, away, { follow.wrappedValue.jumpToNewest() }]
                for step in steps {
                    step()
                    await Task.wait(for: .seconds(1.5))
                }
            }
        }
        #else
        self
        #endif
    }
    #endif

    /// `-CuePadTurnCycle YES`（配录屏）：就绪后把这一处的切页来回翻几遍（"更多"里的移到项目、任务气泡的子任务、搜索的范围），
    /// 第四下落在上一下的弹簧中途（中途反向）。`turn` 是界面上点那一下调的同一条路。
    func debugCyclesTurn(_ turn: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        task {
            guard DebugScene.args.layoutOpts.turnCycle else { return }
            for pause in [3.0, 1.5, 1.5, 0.1, 1.5, 1.5] {
                guard await Task.wait(for: .seconds(pause)) else { return }
                turn()
            }
        }
        #else
        self
        #endif
    }

    /// `-CuePadHelpOpen YES`：问号的说明一出现就点开，同点一下问号（推入转场里栏在动，等它停下再量钮的框）。
    func debugOpensHelp(_ open: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        onAppear { if DebugScene.args.layoutOpts.helpOpen { DebugScene.later(.seconds(1.2), open) } }
        #else
        self
        #endif
    }

    func debugExposesTaskFold(active: Bool = true, _ toggle: @escaping () -> Void) -> some View {
        #if DEBUG
        onChange(of: active, initial: true) { if active, DebugHooks.scripted { DebugScene.toggleTaskFold = toggle } }
        #else
        self
        #endif
    }

    /// 会话页直接打开 `-CuePadOpenPreview <标题或文件名>` 那张预览（对话里的预览到了再找）；`-CuePadQuotePreview <标题或文件名>` 是回复它（`Workspace.quote`）。
    func debugOpensPreview(in items: [ChatEntry], session: SessionState, _ opened: Binding<PreviewOpening?>, quote: @escaping (PreviewItem, UUID) -> Void) -> some View {
        #if DEBUG
        task(id: items.count) {
            let openings = items.flatMap { entry in entry.previews.map { PreviewOpening(preview: $0, batch: entry.previews, group: entry.id.uuidString) } }
            let quoting = DebugScene.args.quotePreview, opening = DebugScene.args.openPreview
            if let quoted = openings.first(where: { $0.preview.title == quoting || $0.preview.name == quoting }), let entry = quoted.entry { quote(quoted.preview, entry) }
            if let shown = openings.first(where: { $0.preview.title == opening || $0.preview.name == opening }) { opened.wrappedValue = shown }
        }
        #else
        self
        #endif
    }

    #if os(iOS)
    /// `-CuePadCompact <宽>`：按这么宽的窄窗口画（模拟器开不了分屏）；`-CuePadWindowSize <宽>x<高>` 同样按这么宽画、尺寸类不变（台前调度里拖小的宽屏窗口）。
    /// 不用场景的尺寸限制（`sizeRestrictions`）摆真窗口：模拟器是全屏应用模式，系统不理它（实测宽一直是整屏）。
    @ViewBuilder func debugCompact() -> some View {
        #if DEBUG
        let width = (DebugScene.args.layoutOpts.compact ?? 0)
        if width > 0 {
            environment(\.horizontalSizeClass, .compact).frame(width: width).frame(maxWidth: .infinity, alignment: .leading)
        } else if let size = DebugScene.windowSize {
            frame(width: size.width).frame(maxWidth: .infinity, alignment: .leading)
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
        overlay { DebugScene.entry?.overlay?(workspace) }
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
    func debugScene(_ workspace: Workspace) -> some View {
        #if DEBUG
        overlay {
            // 盖在根上（在着色的那层外面），自己给系统控件着色
            if let sheet = DebugScene.entry?.overlay?(workspace) { sheet.withPalette() }
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
struct DebugStage<Main: View>: View {
    let workspace: Workspace
    @ViewBuilder let main: () -> Main

    var body: some View {
        #if DEBUG
        if let stage = DebugScene.entry?.stage { stage(workspace) } else { main() }
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
            let asked = args.project == nil ? nil : workspace.currentProject
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
