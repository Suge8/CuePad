#if DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    private static var holds: [String: Int] = [:]
    private static var steps: [String: Int] = [:]
    private static var unsettled: [UUID: String] = [:]
    private static let readyLimit: Duration = .seconds(45)

    static func settling(_ id: UUID, _ place: String?) {
        unsettled[id] = place
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

    nonisolated static func abandon(_ what: String, _ error: any Error) -> Never {
        FileHandle.standardError.write(Data("\(what)：\(error)\n".utf8))
        exit(1)
    }

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

    static func signalReady(_ services: AppServices, _ prepare: () async -> Void) async -> Bool {
        guard let path = readyFile else {
            await prepare()
            return !Task.isCancelled
        }
        let watch = Task {
            guard await Task.wait(for: readyLimit) else { return }
            func named(_ names: [String: Int]) -> [String] { names.sorted { $0.key < $1.key }.map { $1 > 1 ? "\($0) ×\($1)" : $0 } }
            let waiting = named(steps) + named(holds)
                + named(Dictionary(unsettled.values.map { ("\($0) 的视图报着正在过渡", 1) }, uniquingKeysWith: +)) + (animating ? ["屏上有一次性动画"] : [])
            abandon("画面 \(readyLimit.components.seconds) 秒内没有就绪", Unmet("还拖着：\(waiting.isEmpty ? "（没有登记名字的等待）" : waiting.joined(separator: "、"))"))
        }
        defer { watch.cancel() }
        await prepare()
        var still = 0
        while still < 3 {
            guard !Task.isCancelled else { return false }
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
                // 放完了的还挂在层上，要等下一次提交才摘（会话条图标隔几秒敲一下的 `InkBeat`）：舞台开着时对话不排、久不提交，不跳过它就一直算在动
                let ended = animation.beginTime > 0 && layer.convertTime(CACurrentMediaTime(), from: nil) > animation.beginTime + total
                return total.isFinite && total <= Self.longestOneShot && !ended
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
