#if DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    /// 还没做完的摆画面的事（`later`）。
    private static var pending = 0
    /// 正在过渡的视图（`debugSettling`）。
    private static var unsettled: Set<UUID> = []

    static func settling(_ id: UUID, _ busy: Bool) {
        if busy { unsettled.insert(id) } else { unsettled.remove(id) }
    }

    static func later(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        pending += 1
        Task {
            try? await Task.sleep(for: delay)
            work()
            pending -= 1
        }
    }

    /// `-CuePadNotice <文字>`：就绪前弹一条带去处的提示（点它去进展页），停一分钟：截图、录屏拍得到提示条。
    static func noticeIfAsked(_ workspace: Workspace) {
        guard let text = defaults.string(forKey: "CuePadNotice") else { return }
        workspace.say(Dotted(text), status: .unread, link: .progress, duration: .seconds(60))
    }

    /// 就绪文件：脚本起的实例都带（`CUEPAD_SHOT_READY`，见 app.py），App 也据此认出是脚本起的（`DebugHooks.scripted`）。
    static let readyFile = ProcessInfo.processInfo.environment["CUEPAD_SHOT_READY"]

    /// 给了就绪文件时，画面摆好（`prepare` 做完）之后等到：读库的结果都回来了、摆画面的事都做完了、
    /// 没有视图报着正在过渡、屏上没有进行中的一次性动画（转圈这类一直循环的不算），连着三帧都这样，再写下这个文件。`xc.sh shot` 等它出现才截图，不靠固定的等待。
    static func signalReady(_ services: AppServices) async {
        guard let path = readyFile else { return }
        var still = 0
        while still < 3 {
            // 排在页面已经发出的读库之后：它回来时，那些读取也都回来了
            _ = try? await services.store.projects()
            await NextFrame.wait()
            still = pending == 0 && unsettled.isEmpty && !animating ? still + 1 : 0
        }
        FileManager.default.createFile(atPath: path, contents: shotSize.map { Data($0.utf8) })
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

    /// 屏上的窗口里有没有一次性的动画在跑（推入、弹出浮窗这类）；一直循环的（转圈、流光）不算。
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
