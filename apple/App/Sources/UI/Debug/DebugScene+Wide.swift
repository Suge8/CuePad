#if os(macOS) && DEBUG
import AppKit
import CueStore

extension DebugScene {
    /// 组合是 `InteractionBench.wideCases` 的名字（如 `双会话+Cue`），会话取库里前两份。
    /// 窗口用 `-CuePadWindowSize <临界宽>x<高>` 起在临界宽度上（`WideMetrics.railThreshold`，Cue 开着时 1436），不在就以失败退出。
    /// 录出来的每一帧是屏上的样子、不经主线程：`InteractionBench+Wide` 在主线程取样，主线程忙的那几帧取不到，跳没跳要看这里。
    static func reverseWideIfAsked(_ workspace: Workspace) async {
        guard let name = args.layoutOpts.wideReverse else { return }
        await running("摆宽屏组合") {
            await seedRemote(workspace.services)
            let sessions = try await workspace.services.store.piSessionPage(PiSessionQuery(limit: 2)).items.map(\.state.sessionID)
            guard let item = InteractionBench.wideCases.first(where: { $0.name == name }), sessions.count == 2 else {
                throw Unmet("没有「\(name)」这种组合，或库里的会话不够两份")
            }
            InteractionBench.arrange(item, in: workspace, sessions: sessions)
        }
        Task { await cycleWideReverse(workspace) }
    }

    /// 抽屉跨过那一下就关了，拖回窄时不再自己出来（`Workspace.fit`）。只拉出一次。
    static func crossWithDrawerIfAsked(_ workspace: Workspace) {
        guard let which = args.layoutOpts.drawerCross else { return }
        Task {
            // 两次之间停多久是录屏的节奏，不是在等别的事
            await Task.wait(for: .seconds(1))
            guard let window = mainWindow else { return }
            let size = window.contentLayoutRect.size
            if which == "cue" { workspace.showCue() } else { workspace.railDrawer = true }
            await Task.wait(for: .seconds(1.2))
            while !Task.isCancelled {
                window.setContentSize(NSSize(width: size.width + 1, height: size.height))
                await Task.wait(for: .seconds(1.5))
                window.setContentSize(size)
                await Task.wait(for: .seconds(1.5))
            }
        }
    }

    private static func cycleWideReverse(_ workspace: Workspace) async {
        // 两次之间停多久是录屏的节奏，不是在等别的事
        await Task.wait(for: .seconds(1.5))
        guard let window = mainWindow else { return }
        let size = window.contentLayoutRect.size
        let threshold = WideMetrics.railThreshold(cueOpen: workspace.services.settings.cueOpen)
        guard size.width == threshold else { abandon("宽屏反向", Unmet("窗口宽 \(size.width) 不在临界宽度 \(threshold)")) }
        let hold = args.layoutOpts.wideHold ?? 50
        while !Task.isCancelled {
            window.setContentSize(NSSize(width: size.width - 1, height: size.height))
            await Task.wait(for: .milliseconds(hold))
            window.setContentSize(size)
            await Task.wait(for: .seconds(2))
        }
    }
}
#endif
