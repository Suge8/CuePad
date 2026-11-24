import CueStore
import SwiftUI

extension Workspace {
    @discardableResult
    func speak(
        to listener: Listener, from box: Binding<ComposerDraft>, keeping: (ComposerDraft) -> ComposerDraft = { _ in ComposerDraft() },
        saying: Dotted? = nil, as id: UUID = UUID(), content: @escaping (ComposerDraft) -> String
    ) -> Task<Void, Never> {
        let taken = box.wrappedValue
        let kept = keeping(taken)
        let claim = claimImports(taken.withImports(notIn: kept))
        box.wrappedValue = kept
        if let saying { say(saying) }
        return write(to: listener, as: id, taking: {
            let sent = await claim.settled()
            return (sent, content(sent))
        }, restore: { sent in box.wrappedValue = sent.followed(by: box.wrappedValue, keeping: kept) })
    }

    @discardableResult
    func reply(
        to session: SessionState, commands: [SlashCommand], from box: Binding<ComposerDraft>, accepting kinds: ComposerKinds,
        mode: DeliveryMode = .send, card: UUID? = nil, saying: Dotted? = nil, as id: UUID = UUID()
    ) -> Task<Void, Never> {
        if let line = Slash.line(of: box.wrappedValue.accepting(kinds), in: commands, for: session) {
            return speak(to: .session(session, mode: .command, card: card), from: box, keeping: { ComposerDraft(notes: $0.notes) }, saying: saying) { _ in line }
        }
        return speak(to: .session(session, mode: mode, card: card), from: box, saying: saying, as: id) { draft in
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

    @discardableResult
    func speak(_ stored: String, to listener: Listener, saying: Dotted? = nil) -> Task<Void, Never> {
        if let saying { say(saying) }
        return write(stored, to: listener) {}
    }

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

    @discardableResult
    func sayAgain(_ said: Said, restoringInto box: Binding<ComposerDraft>) -> Task<Void, Never> {
        write(said.content, to: said.listener) { box.wrappedValue.append(stored: said.content) }
    }

    func remove(_ said: Said) {
        let services = services
        attempt { try await services.withdraw(said) }
    }

    private func write(_ stored: String, to listener: Listener, restore: @escaping () -> Void) -> Task<Void, Never> {
        write(to: listener, as: UUID(), taking: { (ComposerDraft(), stored) }, restore: { _ in restore() })
    }

    private func write(
        to listener: Listener, as id: UUID, taking: @escaping () async -> (draft: ComposerDraft, body: String), restore: @escaping (ComposerDraft) -> Void
    ) -> Task<Void, Never> {
        let services = services
        if listener.says { launching.begin(id, to: listener.orderKey) }
        return services.sendOrder.enqueue(listener.orderKey) { [self] in
            let (sent, body) = await taking()
            do {
                try await services.recordSpeech(body, to: listener, as: id)
                if listener.says { releaseWhenGone(id) }
            } catch {
                restore(sent)
                launching.release(id)
                fail(error)
            }
        }
    }

}

extension Workspace {
    private func releaseWhenGone(_ id: UUID) {
        let store = services.store, launching = launching
        services.follow { [weak self] in
            let gone = Task { @MainActor in
                do {
                    for try await held in store.observe({ try $0.holdsSpeech(id) }) where !held { break }
                } catch where !Task.isCancelled {
                    self?.fail(error)
                } catch {}
                launching.release(id)
            }
            await withTaskCancellationHandler {
                for await pending in Observations({ launching.holds(id) }) where !pending { break }
            } onCancel: {
                gone.cancel()
            }
            gone.cancel()
            await gone.value
        }
    }
}

extension Listener {
    fileprivate var says: Bool {
        switch self {
        case .cue: true
        case .session(_, _, let mode, _): mode == .send
        }
    }

    var orderKey: SendingTarget {
        switch self {
        case .cue: .cue
        case .session(let target, let host, _, _): SendingTarget(host: host, target: target)
        }
    }
}

extension ComposerDraft {
    func withImports(notIn kept: ComposerDraft) -> ComposerDraft {
        var draft = self
        draft.importing.removeAll { kept.importing.contains($0) }
        return draft
    }

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
