#if DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// 还拖着就绪的事，按名字计数：等过了 `readyLimit` 报出来的就是这些名字。
    private static var holds: [String: Int] = [:]
    /// 正在跑的 `running`，按名字计数：摆画面卡住时报出来的是这些名字（摆画面时另起的常驻任务也在里面，它们不拖就绪）。
    private static var steps: [String: Int] = [:]
    private static var unsettled: Set<UUID> = []
    /// 从摆画面起这么久还没就绪就报出名字退出：要早于脚本从起实例算的 60 秒（`app_proc.READY_TIMEOUT`），晚于最长的正当拖延（`-CuePadQuotaResetIn`，会话里用过最大 30 秒，再加 5 秒）。
    private static let readyLimit: Duration = .seconds(45)

    static func settling(_ id: UUID, _ busy: Bool) {
        if busy { unsettled.insert(id) } else { unsettled.remove(id) }
    }

    static func later(_ delay: Duration, fileID: String = #fileID, line: Int = #line, _ work: @escaping @MainActor () -> Void) {
        holdingReady("\(fileID):\(line)") {
            await Task.wait(for: delay)
            work()
        }
    }

    static func holdingReady(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        count(name, in: &holds, 1)
        Task {
            await work()
            count(name, in: &holds, -1)
        }
    }

    private static func count(_ name: String, in names: inout [String: Int], _ change: Int) {
        names[name, default: 0] += change
        if names[name] == 0 { names[name] = nil }
    }

    /// 录屏都在就绪后才开录（Mac 实测晚 3 秒多），等这么久才录得到进场、停留与收起；`CUEPAD_REC_SECONDS` 给到 18。
    static func noticeIfAsked(_ workspace: Workspace) async {
        guard let text = args.driveOpts.notice else { return }
        await Task.wait(for: .seconds(5))
        workspace.say(Dotted(text), status: .unread, link: .progress, action: .undo("归档") {})
    }

    /// 就绪文件：脚本起的实例都带（`CUEPAD_SHOT_READY`，见 app.py），App 也据此认出是脚本起的（`DebugHooks.scripted`）。
    static let readyFile = ProcessInfo.processInfo.environment["CUEPAD_SHOT_READY"]

    /// 摆画面要的数据没写成：报出原因、以 1 退出，不写就绪文件。等它的脚本（`xc.sh shot`、`perf-mac.sh`）照失败处理，不拿半截的库或画面当成果。
    nonisolated static func abandon(_ what: String, _ error: any Error) -> Never {
        FileHandle.standardError.write(Data("\(what)：\(error)\n".utf8))
        exit(1)
    }

    /// 跑一段调试代码（演示数据、驱动）：任何一步抛错都以失败退出（`abandon`），不吞错；被取消（视图走了、任务收场）是正常结束。
    static func running(_ what: String, _ body: () async throws -> Void) async {
        count(what, in: &steps, 1)
        defer { count(what, in: &steps, -1) }
        do {
            try await body()
        } catch is CancellationError {
            return
        } catch {
            abandon("\(what)失败", error)
        }
    }

    struct Unmet: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// 摆画面（`prepare`），给了就绪文件时再等到：读库的结果都回来了、摆画面的事都做完了、
    /// 没有视图报着正在过渡、屏上没有进行中的一次性动画（转圈这类一直循环的不算），连着三帧都这样，再写下这个文件。`xc.sh shot` 等它出现才截图，不靠固定的等待。
    /// 从摆画面起过了 `readyLimit` 还没写下就报出还在跑、还拖着的名字，以 1 退出。返回 false：任务被取消了（Mac 窗口内容在就绪前被摘下），没写文件，驱动不该再起。
    static func signalReady(_ services: AppServices, _ prepare: () async -> Void) async -> Bool {
        guard let path = readyFile else {
            await prepare()
            return !Task.isCancelled
        }
        let watch = Task {
            guard await Task.wait(for: readyLimit) else { return }
            func named(_ names: [String: Int]) -> [String] { names.sorted { $0.key < $1.key }.map { $1 > 1 ? "\($0) ×\($1)" : $0 } }
            let waiting = named(steps) + named(holds)
                + (unsettled.isEmpty ? [] : ["\(unsettled.count) 处视图报着正在过渡"]) + (animating ? ["屏上有一次性动画"] : [])
            abandon("画面 \(readyLimit.components.seconds) 秒内没有就绪", Unmet("还拖着：\(waiting.isEmpty ? "（没有登记名字的等待）" : waiting.joined(separator: "、"))"))
        }
        defer { watch.cancel() }
        await prepare()
        var still = 0
        while still < 3 {
            guard !Task.isCancelled else { return false }
            // 排在页面已经发出的读库之后：它回来时，那些读取也都回来了
            do {
                _ = try await services.store.projects()
            } catch is CancellationError {
                return false
            } catch {
                abandon("就绪前读库", error)
            }
            await NextFrame.wait()
            still = holds.isEmpty && unsettled.isEmpty && !animating ? still + 1 : 0
        }
        FileManager.default.createFile(atPath: path, contents: shotSize.map { Data($0.utf8) })
        freezeIfAsked()
        return true
    }

    /// `-CuePadFreeze <秒>`：就绪后 1 秒把主线程堵住这么久，核对 `MainThreadWatch` 记下的卡住（存档里的 freeze 那份、设置里的"上次卡住"）。
    private static func freezeIfAsked() {
        let seconds = args.driveOpts.freeze
        guard seconds > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            usleep(useconds_t(seconds * 1_000_000))
        }
    }

    /// Mac：要拍的那扇窗（屏上最大的普通窗口，同 `xc.sh` 取的那扇）按像素算多大，写进就绪文件："宽 高"。
    /// `xc.sh` 拿截到的图、录到的帧和它比：窗口在屏上被系统缩放显示时（调度中心、台前调度开着）截到的是缩小的画面，不能当成果。
    private static var shotSize: String? {
        #if os(macOS)
        let window = NSApp.windows.filter { $0.isVisible && $0.level == .normal }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let window else { return nil }
        let scale = window.backingScaleFactor
        return "\(Int(window.frame.width * scale)) \(Int(window.frame.height * scale))"
        #else
        return nil
        #endif
    }

    private static let longestOneShot: CFTimeInterval = 5

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
}
#endif
