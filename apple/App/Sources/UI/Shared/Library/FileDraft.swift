import CueStore
import Foundation

@Observable
final class FileDraft {
    let file: LibraryFile
    @ObservationIgnored let handle = CardEditing.Handle()
    @ObservationIgnored private(set) var body: String
    private(set) var name = ""
    private(set) var summary = ""
    @ObservationIgnored private var document: SkillDocument?
    @ObservationIgnored private var base: String
    private(set) var dirty = false
    private(set) var blank: Bool
    private(set) var state = State.idle
    var previewing = DebugHooks.args.layoutOpts.mergePreview
    var retire: Set<InstructionSource.Origin> = []
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var autosave: Autosave?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var inflight: String?

    enum State: Equatable {
        case idle
        case saving
        case saved
        case followed
        case conflict(file: String?)
        case failed
    }

    var conflicted: Bool { if case .conflict = state { true } else { false } }

    var text: String { document.map { $0.with(name: name, description: summary, body: body) } ?? body }

    init(_ file: LibraryFile, text: String?, workspace: Workspace) {
        self.file = file
        base = text ?? ""
        body = ""
        self.workspace = workspace
        blank = Self.isBlank(base)
        load(base)
        #if os(macOS)
        autosave = Autosave(save: { [weak self] text in try await self?.write(text) }, onError: { _ in })
        #endif
    }

    func changed(body next: String) {
        body = next
        edited()
    }

    func changed(name next: String) {
        name = next
        edited()
    }

    func changed(summary next: String) {
        summary = next
        edited()
    }

    func fill(_ text: String) {
        handle.replace(text)
        changed(body: text)
    }

    private func edited() {
        mark()
        if case .conflict = state { return }
        autosave?.changed(text)
    }

    func send() async { try? await write(text) }

    private func write(_ text: String) async throws {
        guard let workspace, let library = workspace.library, text == self.text, text != base else { return }
        epoch += 1
        let mine = epoch
        state = .saving
        inflight = text
        defer { if inflight == text { inflight = nil } }
        do {
            try await workspace.saveFile(LibraryEdit(file: file, base: LibraryEdit.base(of: base), text: text), in: library)
            guard epoch == mine else { return }
            base = text
            mark()
            state = dirty ? .idle : .saved
        } catch AgentLibraryError.changedOnMac {
            guard epoch == mine else { return }
            drop()
            state = .conflict(file: nil)
        } catch {
            workspace.fail(error)
            guard epoch == mine else { return }
            state = .failed
            throw error
        }
    }

    private func drop() {
        epoch += 1
        autosave?.discard()
    }

    func follow(_ file: String?) {
        let file = file ?? ""
        if file == text || file == inflight {
            base = file
            mark()
            if conflicted, file == text {
                drop()
                state = .saved
            }
            return
        }
        guard file != base else {
            if conflicted {
                state = .idle
                if dirty { autosave?.changed(text) }
            }
            return
        }
        if dirty {
            drop()
            state = .conflict(file: file)
        } else {
            replace(with: file)
        }
    }

    func takeFile() {
        guard case .conflict(let file?) = state else { return }
        replace(with: file)
    }

    func keepMine() async {
        guard case .conflict(let file?) = state else { return }
        base = file
        mark()
        state = .idle
        try? await write(text)
    }

    private func replace(with file: String) {
        drop()
        base = file
        load(file)
        handle.replace(body)
        mark()
        state = .followed
    }

    private func load(_ text: String) {
        guard case .skill = file else {
            body = text
            return
        }
        let document = SkillDocument(text)
        self.document = document
        name = document.name ?? ""
        summary = document.description ?? ""
        body = document.body
    }

    private func mark() {
        if dirty != (text != base) { dirty = text != base }
        if blank != Self.isBlank(text) { blank.toggle() }
    }

    private static func isBlank(_ text: String) -> Bool { text.allSatisfy(\.isWhitespace) }

    var shownState: String? { Self.shown(state, dirty: dirty) }

    static var longestShownState: String {
        [State.saving, .saved, .followed, .failed, .idle].compactMap { shown($0, dirty: true) }.max { $0.count < $1.count } ?? ""
    }

    private static func shown(_ state: State, dirty: Bool) -> String? {
        #if os(macOS)
        switch state {
        case .saving: SaveState.saving.text
        case .saved: SaveState.saved.text
        case .followed: String(localized: "在别处改过，已跟上")
        case .failed: SaveState.failed.text
        case .idle, .conflict: nil
        }
        #else
        switch state {
        case .saving: String(localized: "正在发往 Mac…")
        case .saved: String(localized: "Mac 上已写好")
        case .followed: String(localized: "Mac 上改过，已跟上")
        case .failed: String(localized: "没发出去")
        case .idle: dirty ? String(localized: "有改动没发") : nil
        case .conflict: nil
        }
        #endif
    }

    func settleSoon() async {
        guard state == .saved || state == .followed else { return }
        #if os(iOS)
        let awaitsMac = true
        #else
        let awaitsMac = false
        #endif
        if await SaveState.linger(awaitsMac: awaitsMac) { state = .idle }
    }

    func leave() async {
        try? await autosave?.flush()
    }
}
