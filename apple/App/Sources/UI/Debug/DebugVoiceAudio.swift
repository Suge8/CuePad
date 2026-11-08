#if os(macOS) && DEBUG
import Foundation
import Observation

/// 高频样本与演示的低频状态分开观察；只有 CueVoiceSignal.body 调用采样闭包时订阅这一份。
@Observable final class DebugVoiceSamples {
    var samples = DebugVoiceAudio.samples(at: 0.35)
}

/// 明示的视觉夹具，只由 DebugVoiceStage 的启动参数启用；正式组件不含音频生成器或定时状态切换。
enum DebugVoiceAudio {
    // 与 VoicePeer 的 sampleMs = 50 对齐；这里只模拟采样值，不连接音频。
    static let interval = 0.05
    static let historyCount = 36

    static func state(at time: TimeInterval) -> String {
        switch time {
        case ..<1.5: "connecting"
        case ..<5: "listening"
        case ..<7: "processing"
        case ..<10.5: "speaking"
        // 开口转向处理的 80ms 内立刻插话，验路径重定向不会等上一段播完。
        case ..<10.58: "processing"
        case ..<12: "listening"
        case ..<15.5: "speaking-muted"
        case ..<17: "muted"
        case ..<20: "failed"
        default: "ended"
        }
    }

    static func samples(at time: TimeInterval) -> [CGFloat] {
        (0..<historyCount).map { index in
            let t = time - Double(historyCount - 1 - index) * interval
            let phrase = max(0, sin(t * 2.7))
            let syllable = 0.5 + 0.5 * sin(t * 12 + sin(t * 3))
            return CGFloat(phrase * (0.2 + 0.8 * syllable))
        }
    }
}
#endif
