#if DEBUG
import CueStore
import CueText
import SwiftUI

extension DebugScene {
    /// 覆盖三道错开的接力与最后一圈落点反馈。
    static let flightProbe = 2.4

    /// `act`：开始量之后当场做的那一下（按发送钮，`pressSendIfAsked`）。
    static func measureFlight(_ kind: String, seconds: Double, into log: URL, act: () -> Void = {}) async throws {
        let turns = TurnLog(), frames = FlightFrames()
        let instructions = instructionsMillions(), energy = energyMillijoules()
        #if os(macOS)
        // 主窗口关着（`-CuePadClosed`）时没有可挂 display link 的窗口：只量指令、CPU 与能量
        if let view = NSApp.windows.first(where: \.isVisible)?.contentView { frames.start(in: view) }
        #else
        frames.start()
        #endif
        turns.begin(CACurrentMediaTime(), root: nil)
        act()
        await Task.wait(for: .seconds(seconds))
        let samples = frames.stop()
        var line = TurnLog.metrics(turns.finish(), instructions: instructions, frames: samples.hitches)
        line["frames"] = samples.intervals.count
        line["over16"] = samples.intervals.filter { $0 > 0.016 }.count
        line["frameMs"] = samples.intervals.map { ($0 * 10_000).rounded() / 10 }
        line["seconds"] = seconds
        line["kind"] = kind
        line["energyMJ"] = ((energyMillijoules() - energy) * 10).rounded() / 10
        for key in ["clickMs", "visibleTurns", "seen", "heavy"] { line[key] = nil }
        let row = try JSONSerialization.data(withJSONObject: line, options: .sortedKeys) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: log.path) {
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: row)
            try handle.close()
        } else {
            try row.write(to: log)
        }
    }
}

/// 接力的帧探针保留全部间隔：60Hz 的正常帧也超过 16ms，不能拿掉帧次数冒充它。
private final class FlightFrames: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh = 1.0 / 60

    #if os(macOS)
    func start(in view: NSView) { start(view.displayLink(target: self, selector: #selector(tick))) }
    #else
    func start() { start(CADisplayLink(target: self, selector: #selector(tick))) }
    #endif

    private func start(_ link: CADisplayLink) {
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        refresh = link.duration > 0 ? link.duration : refresh
    }

    func stop() -> (hitches: FrameRecorder.Hitches, intervals: [Double]) {
        link?.invalidate()
        link = nil
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let slow = zip(stamps.dropFirst(), intervals).filter { $0.1 > refresh * 1.5 }
        return (FrameRecorder.Hitches(
            count: slow.count, worstMs: ((intervals.max() ?? 0) * 10_000).rounded() / 10,
            at: slow.map { [(($0.0 - (stamps.first ?? 0)) * 1000).rounded(), ($0.1 * 10_000).rounded() / 10] }), intervals)
    }
}
#endif
