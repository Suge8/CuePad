#if os(iOS)
import AVFoundation
import CueStore
import os

/// 一通电话对 iOS 音频会话的唯一一次占用（`VoiceAudio` 持有）：建出来时先同步装好监听再激活，激活不成就当场停用、还原、抛出；
/// `end()` 摘监听、停用并还原原来的类别，只做一次。系统收走会话（来电、Siri、闹钟）或媒体服务重置时调 `interrupted`；
/// App 自己停用的（这通或上一通的 `end()`，通知可能晚到）不算。
final class VoiceAudioSession {
    private let previous: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)
    private var observers: [any NSObjectProtocol] = []
    private var interrupted: () -> Void
    private var ended = false
    private static let log = Logger(subsystem: AppIdentity.id, category: "voice")

    init(interrupted: @escaping () -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        previous = (session.category, session.mode, session.categoryOptions)
        self.interrupted = interrupted
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                guard context?.source != .app else { return }
                MainActor.assumeIsolated { self?.interrupt() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt() }
            },
        ]
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            end()
            throw error
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        interrupted = {}
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(previous.category, mode: previous.mode, options: previous.options)
        } catch { Self.log.error("Voice audio session not released: \(error.localizedDescription, privacy: .public)") }
    }

    private func interrupt() {
        let notify = interrupted
        interrupted = {}
        notify()
    }
}
#endif
