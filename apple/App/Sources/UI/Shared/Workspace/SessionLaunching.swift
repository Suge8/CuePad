import CueStore
import Observation
import SwiftUI

/// 归 Workspace 存，视图关了照样等。再开只由 `LaunchProgress.submission` 定。
@Observable
final class SessionLaunching {
    enum Key: Hashable { case form, card(UUID) }

    fileprivate(set) var launch: SessionLaunch?
    fileprivate(set) var progress: LaunchProgress?
    fileprivate(set) var sending = false
    var confirmingAgain = false
    fileprivate(set) var error: String?
    @ObservationIgnored fileprivate var opened: ((LaunchProgress.Claimed) -> Void)?
    @ObservationIgnored fileprivate var again: (() -> Task<Void, Never>?)?
    @ObservationIgnored fileprivate var watching: Task<Void, Never>?

    func phase(at moment: Speech.Moment) -> LaunchProgress.Phase { progress?.phase(at: moment) ?? .idle }

    func canSubmit(at moment: Speech.Moment) -> Bool {
        !sending && (launch == nil || progress?.launch == launch?.request) && progress?.submission(at: moment) != .waiting
    }

    func inFlight(at moment: Speech.Moment) -> Bool {
        guard !sending else { return true }
        guard let launch else { return false }
        switch progress?.launch == launch.request ? phase(at: moment) : .opening {
        case .sending, .opening: return true
        default: return false
        }
    }

    /// `failed` 只在明确没开成或没写出去时为真；未确认、查不到可能已开过，不算。
    func outcome(at moment: Speech.Moment) -> (text: String, failed: Bool)? {
        if let error { return (error, true) }
        return switch phase(at: moment) {
        case .failed(let failure): (failure.text, true)
        case .unconfirmed(let reason): (reason, false)
        case .missing: (String(localized: "上一次开会话的结果已经查不到了"), false)
        default: nil
        }
    }

    @discardableResult
    func launchAgain() -> Task<Void, Never>? {
        confirmingAgain = false
        return again?()
    }

    fileprivate func reset() {
        watching?.cancel()
        (launch, progress, error, confirmingAgain, opened, again, watching) = (nil, nil, nil, false, nil, nil, nil)
    }
}

extension Workspace {
    func sessionLaunching(_ key: SessionLaunching.Key) -> SessionLaunching {
        if let launching = launches[key] { return launching }
        let launching = SessionLaunching()
        launches[key] = launching
        return launching
    }

    @discardableResult
    func submitSession(
        _ start: SessionStart = SessionStart(), in place: ProjectFolders.LaunchPlace?, draft: ComposerDraft, choice: AgentModelChoice?,
        opened: @escaping (LaunchProgress.Claimed) -> Void
    ) -> Task<Void, Never>? {
        guard let place, let host = place.host, let choice, let agent = choice.agent else { return nil }
        let claim = claimImports(draft)
        return launch(sessionLaunching(start.launchKey), opened: opened) { [services] intent in
            let draft = await claim.settled()
            return try await services.launchSession(
                in: place.project.id, prompt: draft.stored.nonEmpty, title: start.name ?? place.project.shownName, on: host,
                card: start.card ?? draft.attachments.first?.card, agent: agent,
                model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast, intent: intent)
        }
    }

    /// `make` 返回 nil 是没开新会话（任务接着用了已有的会话）。
    @discardableResult
    func launch(
        _ launching: SessionLaunching, confirmedAgain: Bool = false, opened: ((LaunchProgress.Claimed) -> Void)? = nil,
        _ make: @escaping (SessionLaunchIntent) async throws -> SessionLaunch?
    ) -> Task<Void, Never>? {
        guard launching.canSubmit(at: services.speech) else { return nil }
        if launching.progress?.submission(at: services.speech) == .confirm, !confirmedAgain {
            launching.again = { [weak self, weak launching] in launching.flatMap { self?.launch($0, confirmedAgain: true, opened: opened, make) } }
            launching.confirmingAgain = true
            return nil
        }
        let intent: SessionLaunchIntent = launching.launch.map { confirmedAgain ? .repeatingConfirmed : .replacing($0.request) } ?? .new
        launching.sending = true
        launching.error = nil
        return Task {
            defer { launching.sending = false }
            do {
                guard let launch = try await make(intent) else { return }
                watch(launching, launch, opened: opened)
            } catch {
                launching.error = error.localizedDescription
                fail(error)
            }
        }
    }

    func resume(_ start: SessionStart, opened: @escaping (LaunchProgress.Claimed) -> Void) {
        let launching = sessionLaunching(start.launchKey)
        if let launch = launching.launch ?? start.launched { watch(launching, launch, opened: opened) }
    }

    #if os(macOS)
    func showLaunched(_ sessionID: String) {
        showsNewSession = false
        show(.session(sessionID))
    }
    #else
    func entering(_ start: SessionStart) -> (LaunchProgress.Claimed) -> Void {
        { [weak self] claimed in if self?.newSession?.id == start.id { self?.claimSession(claimed.id) } }
    }
    #endif

    /// 在途的与可能已开过的（未确认、查不到）不清：认领到时仍要调 `opened`，清掉的话关一次表单就绕过了再开确认。
    func settleLaunch(_ key: SessionLaunching.Key) {
        guard let launching = launches[key], !launching.inFlight(at: services.speech),
              launching.progress?.submission(at: services.speech) != .confirm else { return }
        launching.reset()
    }

    private func watch(_ launching: SessionLaunching, _ launch: SessionLaunch, opened: ((LaunchProgress.Claimed) -> Void)?) {
        launching.opened = opened
        guard launching.launch != launch || launching.watching == nil else { return }
        launching.watching?.cancel()
        launching.launch = launch
        launching.watching = Task { [weak self, store = services.store] in
            do {
                for try await progress in store.observe({ try launch.progress(from: $0) }) {
                    launching.progress = progress
                    guard let claimed = progress.claimed else { continue }
                    let opened = launching.opened
                    launching.reset()
                    opened?(claimed)
                    return
                }
            } catch is CancellationError {
            } catch {
                self?.fail(error)
            }
        }
    }
}

extension View {
    func confirmsLaunchAgain(_ launching: SessionLaunching) -> some View {
        dialog("再开一个会话？", isPresented: Bindable(launching).confirmingAgain, message: "上一次可能已经开了会话，再开可能让 Agent 重复操作。原请求会保留。", buttons: [
            DialogButton(title: "仍然再开") { launching.launchAgain() },
        ])
    }
}
