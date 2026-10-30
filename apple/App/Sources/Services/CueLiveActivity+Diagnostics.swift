#if os(iOS)
import ActivityKit
import CryptoKit
import CueStore
import CueSync
import Foundation
import OSLog
import UIKit

extension CueLiveActivity {
    static func make(
        store: CueStore, sync: (any SyncControlling)?, location: LibraryLocation,
        remoteState: @escaping () throws -> CueActivityState?
    ) -> CueLiveActivity {
        let device = UIDevice.current.identifierForVendor?.uuidString
        let diagnostic = if sync != nil || DebugHooks.recordsActivityDiagnostics, let device {
            ActivityDiagnosticRecorder.shared(directory: location.directory, device: device)
        } else { nil as ActivityDiagnosticRecorder? }
        return CueLiveActivity(store: store, sync: sync, device: device, diagnostic: diagnostic, remoteState: remoteState)
    }

    private static let diagnosticRun = UUID()
    private static var diagnosticSequence = 0
    private static var diagnosticRecording: Task<Void, Never>?
    private static let diagnosticBuild = [
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
        ProcessInfo.processInfo.operatingSystemVersionString,
    ].joined(separator: " / ")

    /// 在原决策点记序号和账号，异步写文件/上传；不在业务的 guard 与动作之间插入 await。
    func trace(
        _ action: ActivityDiagnosticReport.Event.Action, activityID: String? = nil,
        reason: String? = nil, sourceAt: Date? = nil, content: CueActivityState? = nil,
        tokenTag: String? = nil, error: (any Error)? = nil
    ) {
        guard let diagnostic else { return }
        Self.diagnosticSequence += 1
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let contentTag = try content.map { SHA256.hash(data: try encoder.encode($0)).map { String(format: "%02x", $0) }.joined() }
            let event = ActivityDiagnosticReport.Event(
                run: Self.diagnosticRun, sequence: Self.diagnosticSequence, build: Self.diagnosticBuild, action: action,
                activity: activityID, reason: reason, sourceAt: sourceAt ?? content?.now.at, contentTag: contentTag, tokenTag: tokenTag,
                foreground: UIApplication.shared.applicationState != .background,
                errorDomain: error.map { ($0 as NSError).domain }, errorCode: error.map { ($0 as NSError).code })
            let account = try ActivityDiagnosticCloud.account(in: store)
            let previous = Self.diagnosticRecording
            Self.diagnosticRecording = Task {
                await previous?.value
                await diagnostic.record(event, account: account)
            }
        } catch {
            Self.log.error("活动取证未能准备记录：\((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    func traceDestinationRemoval(requested: String?, removed: ActivityDestination?, reason: String) {
        trace(.destinationRemove, activityID: removed?.activityID ?? requested, reason: "\(reason)/requested=\(requested ?? "any")/removed=\(removed?.activityID ?? "none")")
    }

    func watchDiagnosticPhases() {
        guard diagnostic != nil else { return }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            diagnosticTasks.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.trace(.appPhase, reason: name.rawValue)
                }
            })
        }
    }

    func observeDiagnostics(_ activity: Activity<CueActivityAttributes>) {
        guard diagnostic != nil else { return }
        trace(.stateObserved, activityID: activity.id, reason: "\(activity.activityState)")
        trace(.contentObserved, activityID: activity.id, content: activity.content.state)
        diagnosticTasks.append(Task { [weak self] in
            for await content in activity.contentUpdates {
                guard !Task.isCancelled else { return }
                self?.trace(.contentObserved, activityID: activity.id, content: content.state)
            }
        })
        diagnosticTasks.append(Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                self?.trace(.stateObserved, activityID: activity.id, reason: "\(state)")
            }
        })
    }
}
#endif
