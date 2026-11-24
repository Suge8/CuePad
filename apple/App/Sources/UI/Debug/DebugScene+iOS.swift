#if os(iOS) && DEBUG
import CueStore
import CueSync
import SwiftUI
import UIKit

extension DebugScene {
    /// 模拟器当作接了电脑键盘、聚焦不弹软键盘：清掉输入法的硬件键盘布局后照常弹出（私有选择子，只在 Debug 里）。
    private static func showSoftwareKeyboard() {
        let selector = NSSelectorFromString("setHardwareLayout:")
        for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) { mode.perform(selector, with: nil) }
    }

    /// iPad 的窗口模式下系统记着上次的窗口大小（别的调试会话缩过、拖过的窗口下次照那么大起）：调试实例铺满屏，截图、录屏画的是整屏的四列；
    /// 要窄窗口用 `-CuePadCompact`。只撑最小尺寸、不锁死：起来后照样能拖小。
    private static func fillScreenOnPad() {
        guard UIDevice.current.userInterfaceIdiom == .pad, args.layoutOpts.compact == nil,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let restrictions = scene.sizeRestrictions
        else { return }
        restrictions.minimumSize = scene.screen.bounds.size
        Task {
            await NextFrame.wait()
            restrictions.minimumSize = .zero
        }
    }

    /// `-CuePadLiveActivity YES`：系统那份活动换成这次运行的内容才报就绪。活动只有 App 在前台开得出，`xc.sh shot` 一就绪就把 App 切到后台去拍岛；
    /// 同一台模拟器上一张留下的活动还在，所以比的是内容的时刻，不是有没有。钉的样例本就开不出活动的（都歇着）不等。
    private static func holdForLiveActivity() {
        guard args.liveActivity, pinned.cueNow?.hasConfirmedActivity != false else { return }
        holdingReady("实时活动换成这次的（-CuePadLiveActivity）") {
            while CueLiveActivity.running.first.map({ $0.content.state.now.at < PerfProbe.processStart }) ?? true {
                guard await Task.wait(for: .milliseconds(100)) else { return }
            }
        }
    }

    static func prepare(_ workspace: Workspace) async {
        if args.driveOpts.bench == "interact" { IOSInteractionBench.beginCold() }
        dumpAccessibilityIfAsked()
        logAccessibilityFocusIfAsked()
        if args.layoutOpts.softKeyboard { showSoftwareKeyboard() }
        fillScreenOnPad()
        let project = await prepareLibrary(workspace)
        if args.demo {
            await seedRemote(workspace.services)
            if !["cue", "cuememory", "cueschedules"].contains(scene ?? "") { await seedCue(workspace.services) }
        }
        if args.demoMac { Task { await runDemoMac(workspace.services) } }
        Task { await phoneVoiceCallIfAsked(workspace) }
        if args.noAsks { await settleAsks(workspace.services.store) }
        await IslandBench.run(workspace.services)
        holdForLiveActivity()
        if args.driveOpts.bench == "interact" {
            Task { await IOSInteractionBench.run(workspace) }
            return
        }
        presetColumns(workspace.services.settings)
        if let prepare = entry?.prepare { await running("摆画面") { try await prepare(workspace, project) } }
        await presetBeside(workspace)
        presetDrawers(workspace)
        await presetSpeech(workspace)
        await prepareNarrow(workspace)
        await openLivePhoneIfAsked(workspace)
        if let pace = args.layoutOpts.sidebarCycle { Task { await cycleColumn(fast: pace == "fast") { workspace.railExpanded.toggle() } } }
        if let pace = args.layoutOpts.rightCycle { Task { await cycleColumn(fast: pace == "fast") { workspace.services.settings.cueOpen.toggle() } } }
    }

    static func openCard(_ workspace: Workspace, project: UUID?) async throws {
        if let project { workspace.select(.project(project)) }
        if let card = try await card(in: project ?? Project.defaultID, store: workspace.services.store) { workspace.push(.card(card)) }
    }

    static func demoSession(titled title: String, store: CueStore) async throws -> SessionState? {
        try await store.sessionPage(SessionQuery(text: title)).items.first { $0.state.title == title }?.state
    }

    static func cyclePanel() async {
        await Task.wait(for: .seconds(4))
        for _ in 0..<8 {
            toggleCuePanel()
            await Task.wait(for: .seconds(1.5))
        }
    }
}
#endif

