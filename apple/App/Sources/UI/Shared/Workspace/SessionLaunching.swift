import CueStore
import Observation
import SwiftUI

/// 开一个新会话、等它认领的那一次：Mac 的新会话表单、Mac 任务的"开始"、手机的新会话输入框共用，归 Workspace 按卡片或表单存（`Workspace.sessionLaunching(_:)`），
/// 视图关了照样等。再开只由进度定（`LaunchProgress.submission`）：可安全替换就直接替换或重试，可能已开过要先确认（`confirmingAgain`，
/// 确认后原样再开被拦下的那一次，`launchAgain`），在等着时不能再开。
@Observable
final class SessionLaunching {
    enum Key: Hashable { case form, card(UUID) }

    fileprivate(set) var launch: SessionLaunch?
    fileprivate(set) var progress: LaunchProgress?
    fileprivate(set) var sending = false
    var confirmingAgain = false
    /// 没能写出请求的原因（Store 拒绝重复交出、这台 Mac 一家 Agent 都没有）。
    fileprivate(set) var error: String?
    @ObservationIgnored fileprivate var opened: ((LaunchProgress.Claimed) -> Void)?
    @ObservationIgnored fileprivate var again: (() -> Task<Void, Never>?)?
    @ObservationIgnored fileprivate var watching: Task<Void, Never>?

    func phase(at moment: Speech.Moment) -> LaunchProgress.Phase { progress?.phase(at: moment) ?? .idle }

    func canSubmit(at moment: Speech.Moment) -> Bool {
        !sending && (launch == nil || progress?.launch == launch?.request) && progress?.submission(at: moment) != .waiting
    }

    /// 发出了、还没有结果（在路上、等 Agent 连上）：Mac 的表单这时锁住，表单关上也不清掉。
    func inFlight(at moment: Speech.Moment) -> Bool {
        guard !sending else { return true }
        guard let launch else { return false }
        switch progress?.launch == launch.request ? phase(at: moment) : .opening {
        case .sending, .opening: return true
        default: return false
        }
    }

    /// 上一次要交代的结果（Mac 的表单与任务那一行）：`failed` 是明确没开成或没写出去，可能已开过（未确认、查不到）不是。在途或没发过为 nil。
    func outcome(at moment: Speech.Moment) -> (text: String, failed: Bool)? {
        if let error { return (error, true) }
        return switch phase(at: moment) {
        case .failed(let failure): (failure.text, true)
        case .unconfirmed(let reason): (reason, false)
        case .missing: (String(localized: "上一次开会话的结果已经查不到了"), false)
        default: nil
        }
    }

    /// 确认框里点了"仍然再开"。
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

    /// 新会话表单（Mac 的表单、手机的输入框）发出开场：等附件存好再写请求；认领到时调 `opened`。
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

    /// 三个入口共用的一次提交：在等着就不提交；可能已开过又没确认就先问（`confirmingAgain`）；否则按已发的那次定意图交给 `make` 写请求，
    /// 写出后跟着它的进度。`make` 返回 nil 是没开新会话（任务接着用了已有的会话）。
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

    /// 接着看已经发出的那一次（手机重开同一任务的输入框，`SessionStart.launched`）。
    func resume(_ start: SessionStart, opened: @escaping (LaunchProgress.Claimed) -> Void) {
        let launching = sessionLaunching(start.launchKey)
        if let launch = launching.launch ?? start.launched { watch(launching, launch, opened: opened) }
    }

    #if os(macOS)
    /// Mac 的新会话表单认领到时（表单关了也算）：收起表单，在内容区打开新会话。
    func showLaunched(_ sessionID: String) {
        showsNewSession = false
        show(.session(sessionID))
    }
    #else
    /// 手机的输入框认领到时：还开着这一次就收起、进入新会话；关了就留在原处。
    func entering(_ start: SessionStart) -> (LaunchProgress.Claimed) -> Void {
        { [weak self] claimed in if self?.newSession?.id == start.id { self?.claimSession(claimed.id) } }
    }
    #endif

    /// 表单关上：它那一份不在途就清掉，下次打开是新的；在途的接着等，认领到时照样调 `opened`。
    func settleLaunch(_ key: SessionLaunching.Key) {
        if let launching = launches[key], !launching.inFlight(at: services.speech) { launching.reset() }
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
    /// 可能已开过会话时再开的确认（`SessionLaunching.confirmingAgain`），三个入口同一个。
    func confirmsLaunchAgain(_ launching: SessionLaunching) -> some View {
        dialog("再开一个会话？", isPresented: Bindable(launching).confirmingAgain, message: "上一次可能已经开了会话，再开可能让 Agent 重复操作。原请求会保留。", buttons: [
            DialogButton(title: "仍然再开") { launching.launchAgain() },
        ])
    }
}
