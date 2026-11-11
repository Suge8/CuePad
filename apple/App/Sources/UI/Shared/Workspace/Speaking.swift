import CueStore
import SwiftUI

/// 发消息只有这一条路（全 App 所有入口）：按下发送 → 同步取走草稿、清空输入框（在任何 await 之前）→ 写一条记录 → 后台立即上传。
/// 界面从不等上传或执行结果，到哪了只看记录（`Speech`）。只有写库本身失败时草稿放回输入框（期间新打的字接在后面）并提示。
/// 落库与全 App 的发送顺序归 AppServices，语音和多个窗口共用。
extension Workspace {
    /// `keeping` 是发出后输入框里留下的（斜杠命令留着批注跟下一句发）。返回写库与上传的那个任务（测试等它）。
    @discardableResult
    func speak(
        to listener: Listener, from box: Binding<ComposerDraft>, keeping: (ComposerDraft) -> ComposerDraft = { _ in ComposerDraft() },
        saying: Dotted? = nil, content: @escaping (ComposerDraft) -> String
    ) -> Task<Void, Never> {
        let taken = box.wrappedValue
        let kept = keeping(taken)
        let claim = claimImports(taken.withImports(notIn: kept))
        box.wrappedValue = kept
        if let saying { say(saying) }
        return write(to: listener, taking: {
            let sent = await claim.settled()
            return (sent, content(sent))
        }, restore: { sent in box.wrappedValue = sent.followed(by: box.wrappedValue, keeping: kept) })
    }

    @discardableResult
    func reply(
        to session: SessionState, commands: [SlashCommand], from box: Binding<ComposerDraft>, accepting kinds: ComposerKinds,
        mode: DeliveryMode = .send, card: UUID? = nil, saying: Dotted? = nil
    ) -> Task<Void, Never> {
        if let line = Slash.line(of: box.wrappedValue.accepting(kinds), in: commands, for: session) {
            return speak(to: .session(session, mode: .command, card: card), from: box, keeping: { ComposerDraft(notes: $0.notes) }, saying: saying) { _ in line }
        }
        return speak(to: .session(session, mode: mode, card: card), from: box, saying: saying) { draft in
            let draft = draft.accepting(kinds)
            return Slash.said(draft, in: commands, for: session) ?? draft.stored
        }
    }

    @discardableResult
    func answer(_ session: SessionState, from box: Binding<ComposerDraft>) -> Task<Void, Never> {
        speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func quote(_ preview: PreviewItem, in entry: UUID, of session: SessionState) {
        services.settings.quote(preview, in: entry, for: session.id)
        replyFocus = session.id
    }

    /// 不是从输入框说的（任务的正文、压缩按钮）：写不进库时只提示，原文还在原处。
    @discardableResult
    func speak(_ stored: String, to listener: Listener, saying: Dotted? = nil) -> Task<Void, Never> {
        if let saying { say(saying) }
        return write(stored, to: listener) {}
    }

    /// 撤不回（Mac 已领取、Cue 已收到）就不重发，免得说两遍；撤回之后写不进库时，原文放进 `box`（这个去处的输入框），文字不丢。
    @discardableResult
    func resend(_ said: Said, restoringInto box: Binding<ComposerDraft>) -> Task<Void, Never> {
        let services = services
        return Task {
            do {
                try await services.withdraw(said)
                await self.write(said.content, to: said.listener) {
                    box.wrappedValue.append(stored: said.content)
                }.value
            } catch { fail(error) }
        }
    }

    /// 用户确认可能重复后明确再说一次：新建意图，保留原请求的未知，不把它删除后伪装成安全重投。
    @discardableResult
    func sayAgain(_ said: Said, restoringInto box: Binding<ComposerDraft>) -> Task<Void, Never> {
        write(said.content, to: said.listener) { box.wrappedValue.append(stored: said.content) }
    }

    func remove(_ said: Said) {
        let services = services
        attempt { try await services.withdraw(said) }
    }

    private func write(_ stored: String, to listener: Listener, restore: @escaping () -> Void) -> Task<Void, Never> {
        write(to: listener, taking: { (ComposerDraft(), stored) }, restore: { _ in restore() })
    }

    private func write(
        to listener: Listener, taking: @escaping () async -> (draft: ComposerDraft, body: String), restore: @escaping (ComposerDraft) -> Void
    ) -> Task<Void, Never> {
        let services = services
        // 同一个去处的话按按下的先后落库：前一句在等附件存好时，后一句也等它（只等落库，不等上传）
        let recording = services.sendOrder.enqueue(listener.orderKey) { [self] in
            let id: UUID
            let (sent, body) = await taking()
            do {
                id = try await services.recordSpeech(body, to: listener)
            } catch {
                restore(sent)
                switch listener {
                case .cue: cue.launchFailed()
                case .session(let target, let host, _, _): launching.settle(host: host, target: target)
                }
                fail(error)
                throw error
            }
            return id
        }
        return Task {
            if case .success(let id) = await recording.result { await services.upload(id) }
        }
    }

}

extension Listener {
    var orderKey: SendingTarget {
        switch self {
        case .cue: .cue
        case .session(let target, let host, _, _): SendingTarget(host: host, target: target)
        }
    }
}

extension ComposerDraft {
    /// 去掉还留在输入框（`kept`）里的在存附件编号：它们存好后接给输入框，不随取走的这份发出。
    func withImports(notIn kept: ComposerDraft) -> ComposerDraft {
        var draft = self
        draft.importing.removeAll { kept.importing.contains($0) }
        return draft
    }

    /// 发出时就留在输入框里的（`kept`）本来就在取走的里，不算新打的。
    func followed(by later: ComposerDraft, keeping kept: ComposerDraft) -> ComposerDraft {
        var merged = self
        let typed = later.text == kept.text ? "" : later.text
        merged.text = [text, typed].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        merged.files += later.files.filter { !files.contains($0) }
        merged.attachments += later.attachments.filter { outbox in !attachments.contains { $0.card == outbox.card && $0.content == outbox.content } }
        merged.notes += later.notes.filter { note in !notes.contains { $0.id == note.id } }
        merged.importing = later.importing
        return merged
    }
}
