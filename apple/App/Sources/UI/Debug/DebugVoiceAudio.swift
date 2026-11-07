#if os(macOS) && DEBUG
import Foundation

/// 明示的视觉夹具，只由 DebugVoiceStage 的启动参数启用；正式组件不含音频生成器或定时状态切换。
enum DebugVoiceAudio {
    // 与 VoicePeer 的 sampleMs = 50 对齐；这里只模拟采样值，不连接音频。
    static let interval = 0.05
    static let historyCount = 36

    static func state(at time: TimeInterval) -> String {
        switch time {
        case ..<1.7: "listening"
        case ..<3: "processing"
        case ..<5.1: "speaking"
        // 开口转向处理的 80ms 内立刻插话，验路径重定向不会等上一段播完。
        case ..<5.18: "processing"
        case ..<6.2: "listening"
        case ..<6.9: "speaking"
        case ..<8: "muted"
        default: "failed"
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
