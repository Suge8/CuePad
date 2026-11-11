#if os(macOS) && DEBUG
import AppKit
import CueStore
import os

/// 主区按新宽重排一次的开销（#74）：宽屏开合要逐帧排版（每帧按当时的宽排整页），前提是这一下远低于一帧。只在 `-CuePadInteractOnly` 点名时量
/// （`换宽·会话页`、`换宽·看板`、`换宽·项目页`），不进整套流程。
/// 窗口 1440 宽、会话条与 Cue 开着（主区 784），只挪主区那一块：左缘一步 8 点往左挪、右缘不动，走完会话条的 256 点再走回来（同会话条藏起、放回时主区走过的那一段），
/// 窗口与别的栏不动。每一步同步排完、画完、提交（`layoutSubtreeIfNeeded`、`displayIfNeeded`、`CATransaction.flush`），再等两帧，把挪到后面的活（几何读数写回的状态）也算进来。
/// 行里 `clickMs`、`clickInstructionsM`、`clickCyclesM` 是每一步主线程 CPU 毫秒、指令与周期（百万）的中位数，`p90InstructionsM` 是九成分位，
/// `syncInstructionsM` 是同步那一段的中位数，`instructionsM` 是整段走下来的合计。机器忙时 CPU 毫秒被拉长，和目标比用周期按性能核的频率折算（M4 Pro 4.5GHz：45M 周期约 10ms）。
extension InteractionBench {
    private static let relayoutPages = ["换宽·会话页", "换宽·看板", "换宽·项目页"]
    /// 一步挪多少：会话条开合在约 30 帧里挪 256 点。
    private static let relayoutStep: CGFloat = 8
    private static let relayoutWindow: CGFloat = 1440
    /// 一次换宽的目标（#74）：大库三页中位 8ms 以内，逐帧排版才在一帧里放得下。
    private static let relayoutBudget: Double = 8

    static func measureRelayout(_ workspace: Workspace, in window: NSWindow, sessions: [String], only: Set<String>?) async throws {
        let wanted = relayoutPages.filter { only?.contains($0) == true }
        guard !wanted.isEmpty, let root = window.contentView else { return }
        let store = workspace.services.store
        let longest = try await store.sessionPage(SessionQuery(id: SessionState.recordID(sessionID: PerfLibrary.longestChat))).items.first
        let session = longest?.state.sessionID ?? sessions.first
        let project = workspace.catalog?.summaries.max(by: { $0.value.cardCount < $1.value.cardCount })?.key
        let settings = workspace.services.settings
        settings.railExpanded = true
        settings.cueOpen = true
        window.setContentSize(NSSize(width: relayoutWindow, height: window.contentLayoutRect.height))
        let port = mach_thread_self()
        let shifts = Array(stride(from: relayoutStep, through: Chrome.rail, by: relayoutStep)) + Array(stride(from: Chrome.rail - relayoutStep, through: 0, by: -relayoutStep))
        for name in wanted {
            switch name {
            case "换宽·会话页": if let session { workspace.show(.session(session)) } else { continue }
            case "换宽·看板": workspace.show(.progress)
            default: if let project { workspace.show(.project(project)) } else { continue }
            }
            await Task.wait(for: .seconds(2))
            guard let column = wideColumns(in: root).first(where: { $0.slot == .main }) else { throw DebugScene.Unmet("换宽测量找不到主区") }
            let frame = column.frame
            var steps: [(ms: Double, instructions: Double, cycles: Double, sync: Double)] = []
            let interval = signposter.beginInterval("交互", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
            for shift in shifts {
                let before = threadCountersMillions(), cpu = mainCPUSeconds(port)
                column.frame = CGRect(x: frame.minX - shift, y: frame.minY, width: frame.width + shift, height: frame.height)
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                let sync = threadInstructionsMillions() - before.instructions
                await NextFrame.drawn()
                let after = threadCountersMillions()
                steps.append(((mainCPUSeconds(port) - cpu) * 1000, after.instructions - before.instructions, after.cycles - before.cycles, sync))
            }
            signposter.endInterval("交互", interval)
            column.frame = frame
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
            let counts = steps.map(\.instructions)
            let row: [String: Any] = [
                "name": name, "clickMs": round(median(steps.map(\.ms))), "clickInstructionsM": round(median(counts)), "clickCyclesM": round(median(steps.map(\.cycles))),
                "p90InstructionsM": round(counts.sorted()[counts.count * 9 / 10]), "syncInstructionsM": round(median(steps.map(\.sync))),
                "instructionsM": round(counts.reduce(0, +)), "totalMs": round(steps.map(\.ms).reduce(0, +)), "maxTurnMs": round(steps.map(\.ms).max() ?? 0),
                "clickGHz": 0, "seen": true, "hitches": 0, "worstMs": 0, "hitchesAt": [Double](), "budgetClickMs": relayoutBudget, "budgetHitches": 0,
            ]
            print(jsonLine("INTERACT", row))
            fflush(stdout)
        }
    }
}
#endif
