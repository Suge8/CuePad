import AVFoundation
import os
#if os(iOS)
import UIKit
#endif

extension VoicePeer {
    func trace(_ stage: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        AppServices.log.notice("Voice media session=\(self.session.uuidString, privacy: .public) uptime=\(uptime) stage=\(stage, privacy: .public) app=\(UIApplication.shared.applicationState.rawValue) permission=\(AVAudioApplication.shared.recordPermission.rawValue) category=\(audio.category.rawValue, privacy: .public) mode=\(audio.mode.rawValue, privacy: .public)")
        #else
        AppServices.log.notice("Voice media session=\(self.session.uuidString, privacy: .public) uptime=\(uptime) stage=\(stage, privacy: .public)")
        #endif
    }

    #if os(iOS)
    func traceAudio(name: Notification.Name, context: AVAudioSession.DeactivationContext?, resume: AVAudioSession.ResumptionContext?, shared: Bool) {
        let source = context?.source.rawValue ?? -1
        let reason = context?.interruptionContext.map { Int($0.reason.rawValue) } ?? -1
        let recommendation = resume?.recommendation.rawValue ?? -1
        AppServices.log.notice("Voice audio session=\(self.session.uuidString, privacy: .public) notification=\(name.rawValue, privacy: .public) source=\(source) reason=\(reason) resume=\(recommendation) shared=\(shared)")
        trace("audio-notification")
    }
    #endif
}
