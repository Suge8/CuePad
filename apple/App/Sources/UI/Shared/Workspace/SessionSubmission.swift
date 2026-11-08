import CueStore
import Observation

/// 手机与平板允许等待中继续编辑；只有当前请求的进度才能授权替换或确认另开。
@Observable
final class SessionSubmission {
    var launched: SessionLaunch?
    var progress: LaunchProgress?
    var sending = false
    var confirmingAgain = false

    func canSubmit(on host: String?, agent: AgentKind?, at moment: Speech.Moment) -> Bool {
        host != nil && agent != nil && !sending
            && (launched == nil || progress?.launch == launched?.request)
            && progress?.submission(at: moment) != .waiting
    }
}

extension Workspace {
    @discardableResult
    func submitSession(
        _ submission: SessionSubmission, start: SessionStart, in place: ProjectFolders.LaunchPlace?,
        draft: ComposerDraft, choice: AgentModelChoice?, confirmedAgain: Bool = false
    ) -> Task<Void, Never>? {
        guard let place, let host = place.host, let choice, let agent = choice.agent,
              submission.canSubmit(on: host, agent: agent, at: services.speech) else { return nil }
        if submission.progress?.submission(at: services.speech) == .confirm, !confirmedAgain {
            submission.confirmingAgain = true
            return nil
        }
        let intent: SessionLaunchIntent = submission.launched.map {
            confirmedAgain ? .repeatingConfirmed : .replacing($0.request)
        } ?? .new
        let claim = claimImports(draft)
        submission.sending = true
        return Task {
            defer { submission.sending = false }
            let draft = await claim.settled()
            do {
                submission.launched = try await launchSession(
                    in: place.project.id, prompt: draft.stored.nonEmpty, title: start.name ?? place.project.shownName, on: host,
                    card: start.card ?? draft.attachments.first?.card, agent: agent,
                    model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast, intent: intent)
            } catch { fail(error) }
        }
    }
}
