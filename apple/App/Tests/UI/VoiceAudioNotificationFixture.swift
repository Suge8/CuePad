#if os(iOS)
import AVFoundation
import ObjectiveC

// 系统上下文禁止公开初始化；替身只覆盖只读属性，不依赖系统对象的私有存储或构造器。
nonisolated class VoiceSystemDeactivation: AVAudioSession.DeactivationContext, @unchecked Sendable {
    override var source: AVAudioSession.DeactivationSource { .system }
    override var interruptionContext: AVAudioSession.InterruptionContext? {
        class_createInstance(VoiceSystemInterruption.self, 0) as? VoiceSystemInterruption
    }
}

nonisolated final class VoiceAppDeactivation: VoiceSystemDeactivation, @unchecked Sendable {
    override var source: AVAudioSession.DeactivationSource { .app }
}

nonisolated final class VoiceIdleDeactivation: VoiceSystemDeactivation, @unchecked Sendable {
    override var interruptionContext: AVAudioSession.InterruptionContext? { nil }
}

nonisolated final class VoiceSystemInterruption: AVAudioSession.InterruptionContext, @unchecked Sendable {
    override var reason: AVAudioSession.InterruptionReason { .builtInMicMuted }
}
#endif
