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

    static func prepare(_ workspace: Workspace) async {
        if args.driveOpts.bench == "interact" { IOSInteractionBench.beginCold() }
        dumpAccessibilityIfAsked()
        logAccessibilityFocusIfAsked()
        if args.layoutOpts.softKeyboard { showSoftwareKeyboard() }
        fillScreenOnPad()
        let project = await prepareLibrary(workspace)
        if args.demo {
            await seedRemote(workspace.services)
            // Cue 在演示 Mac 上值班才有"等 Cue 回答"与待回复：每个画面都写（已写过就不再写）；Cue 页那几档在摆画面时按各自的先后写
            if !["cue", "cuememory", "cueschedules"].contains(scene ?? "") { await seedCue(workspace.services) }
        }
        if args.demoMac { Task { await runDemoMac(workspace.services) } }
        Task { await phoneVoiceCallIfAsked(workspace) }
        if args.noAsks { await settleAsks(workspace.services.store) }
        await IslandBench.run(workspace.services)  // 跑完才报就绪：xc.sh run 一直持有这台模拟器，别的任务换不掉它
        if args.driveOpts.bench == "interact" {
            Task { await IOSInteractionBench.run(workspace) }
            return
        }
        presetColumns(workspace.services.settings)
        if let prepare = entry?.prepare { await running("摆画面") { try await prepare(workspace, project) } }
        presetDrawers(workspace)
        await presetSpeech(workspace)
        await prepareNarrow(workspace)
        if let pace = args.layoutOpts.sidebarCycle { Task { await cycleWide(fast: pace == "fast") { workspace.railExpanded.toggle() } } }
        if let pace = args.layoutOpts.rightCycle { Task { await cycleWide(fast: pace == "fast") { workspace.services.settings.cueOpen.toggle() } } }
    }

    private static func cycleWide(fast: Bool, _ toggle: () -> Void) async {
        // 两次之间停多久是录屏的节奏，不是在等别的事
        let gaps: [Double] = fast ? [0.1, 1.5, 0.06, 0.06, 1.5] : [1.5]
        await Task.wait(for: .seconds(3))
        var step = 0
        while !Task.isCancelled {
            toggle()
            await Task.wait(for: .seconds(gaps[step % gaps.count]))
            step += 1
        }
    }

    static func openCard(_ workspace: Workspace, project: UUID?) async throws {
        if let project { workspace.select(.project(project)) }
        if let card = try await card(in: project ?? Project.defaultID, store: workspace.services.store) { workspace.push(.card(card)) }
    }

    static func demoSession(titled title: String, store: CueStore) async throws -> SessionState? {
        try await store.piSessionPage(SessionQuery(text: title)).items.first { $0.state.title == title }?.state
    }

    /// 演示模式没有同步，真实状态出不来。
    static var alertStatus: AlertStatus? {
        switch args.alertStatus {
        case "on": AlertStatus(authorization: .authorized, registration: .registered, subscription: .active)
        case "pending": AlertStatus(authorization: .authorized, registration: .pending, subscription: .off)
        case "denied": AlertStatus(authorization: .denied, registration: .pending, subscription: .off)
        case "undetermined": AlertStatus(authorization: .notDetermined, registration: .pending, subscription: .off)
        case "registerFailed": AlertStatus(authorization: .authorized, registration: .failed(String(localized: "没有连接到 Apple 推送服务", table: "Demo")), subscription: .off)
        case "subscribeFailed": AlertStatus(authorization: .authorized, registration: .registered, subscription: .failed(String(localized: "iCloud 账号不可用", table: "Demo")))
        default: nil
        }
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

