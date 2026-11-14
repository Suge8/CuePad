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
    @ObservationIgnored fileprivate var opened: Workspace.LaunchOpened?
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

    deinit { watching?.cancel() }

    fileprivate func reset() {
        watching?.cancel()
        (launch, progress, error, confirmingAgain, opened, again, watching) = (nil, nil, nil, false, nil, nil, nil)
    }
}

extension Workspace {
    /// 认领到时调，存到那时为止（可能永远不来）。它与再开要用的 `LaunchMaking` 都存在进度里（`SessionLaunching` 归工作区存）：
    /// 工作区作为参数给，闭包里不必也别去攥着它，不然工作区与它的进度互相攥着都放不掉。
    typealias LaunchOpened = (Workspace, LaunchProgress.Claimed) -> Void
    /// 返回 nil 是没开新会话（任务接着用了已有的会话）。
    typealias LaunchMaking = (Workspace, SessionLaunchIntent) async throws -> SessionLaunch?

    func sessionLaunching(_ key: SessionLaunching.Key) -> SessionLaunching {
        if let launching = launches[key] { return launching }
        let launching = SessionLaunching()
        launches[key] = launching
        return launching
    }

    @discardableResult
    func submitSession(
        in place: ProjectFolders.LaunchPlace?, draft: ComposerDraft, choice: AgentModelChoice?,
        opened: @escaping LaunchOpened
    ) -> Task<Void, Never>? {
        guard let place, let host = place.host, let choice, let agent = choice.agent else { return nil }
        // 新会话要有东西交给 Agent：一句话、附件或带上的任务，空着不开
        guard !draft.isEmpty(accepting: [.files, .cards]) else { return nil }
        let claim = claimImports(draft)
        return launch(sessionLaunching(.form), opened: opened) { [services] _, intent in
            let draft = await claim.settled()
            return try await services.launchSession(
                in: place.project.id, prompt: draft.stored.nonEmpty, title: place.project.shownName, on: host,
                card: draft.attachments.first?.card, agent: agent,
                model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast, intent: intent)
        }
    }

    @discardableResult
    func launch(
        _ launching: SessionLaunching, confirmedAgain: Bool = false, opened: LaunchOpened? = nil,
        _ make: @escaping LaunchMaking
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
                guard let launch = try await make(self, intent) else { return }
                watch(launching, launch, opened: opened)
            } catch {
                launching.error = error.localizedDescription
                fail(error)
            }
        }
    }

    /// 输入框重新出现：还在等的那一次接着等，认领到时按这一次的 `opened` 收尾。
    func resume(_ key: SessionLaunching.Key, opened: LaunchOpened?) {
        let launching = sessionLaunching(key)
        if let launch = launching.launch { watch(launching, launch, opened: opened) }
    }

    /// 接上一次已经发出、这里还不知道的（同一件任务在别处或上一次运行时发的，从库里读出来）：接着看进度，再开时照样确认重复风险。
    func resume(_ key: SessionLaunching.Key, with launch: SessionLaunch, opened: LaunchOpened?) {
        watch(sessionLaunching(key), launch, opened: opened)
    }

    /// 认领到新会话：收起输入框、进那个会话。输入框中途关了的，Mac 照样进（请求是在这台发的，人还在这儿），手机留在原处。
    static func entering(_ start: SessionStart) -> LaunchOpened {
        { workspace, claimed in
            #if os(macOS)
            workspace.newSession = nil
            workspace.show(.session(claimed.sessionID))
            #else
            guard workspace.newSession?.id == start.id else { return }
            workspace.newSession = nil
            workspace.openSession(claimed.id)
            #endif
        }
    }

    /// 在途的与可能已开过的（未确认、查不到）不清：认领到时仍要调 `opened`，清掉的话关一次表单就绕过了再开确认。
    func settleLaunch(_ key: SessionLaunching.Key) {
        guard let launching = launches[key], !launching.inFlight(at: services.speech),
              launching.progress?.submission(at: services.speech) != .confirm else { return }
        launching.reset()
    }

    private func watch(_ launching: SessionLaunching, _ launch: SessionLaunch, opened: LaunchOpened?) {
        launching.opened = opened
        guard launching.launch != launch || launching.watching == nil else { return }
        launching.watching?.cancel()
        launching.launch = launch
        // 弱持有：工作区（iOS 每个窗口一份）连同它的进度一起没了，这一路订阅就随进度的 deinit 取消，不等一次永远不来的认领
        launching.watching = Task { [weak self, weak launching, store = services.store] in
            do {
                for try await progress in store.observe({ try launch.progress(from: $0) }) {
                    guard let self, let launching else { return }
                    launching.progress = progress
                    guard let claimed = progress.claimed else { continue }
                    let opened = launching.opened
                    launching.reset()
                    opened?(self, claimed)
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
