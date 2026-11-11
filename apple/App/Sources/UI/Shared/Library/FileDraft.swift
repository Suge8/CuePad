import CueStore
import Foundation

/// 一份技能或规则文件此刻的改动（Mac 与手机的文件页同一份）：文件是事实，这里是你改着的那一版。
/// - 规则只有正文；技能分三处改——name、description 两个输入框与正文编辑器，写回时合成整份 SKILL.md，其余 frontmatter 原样（`SkillDocument`）。
///   编辑器是正文的唯一写者，`body` 只在它报来时变。
/// - `base` 是以为文件此刻的样子（打开时读到的、自己写成的、跟上的那一版）；写入都带它的哈希（`LibraryEdit.base`），
///   文件已不是它，那台 Mac 就不写（`AgentLibraryError.changedOnMac`）。
/// - Mac 自动存（停手一小会儿，同灵感的编辑页，`Autosave`），没有保存钮；手机攒着，点纸飞机"发往 Mac"（`send`）。
/// - 写入是异步的：每次写入和每次“换了说法”（跟上文件、进入冲突、丢下排着的）都会换一个代次（`epoch`），写完时代次已变就什么都不改——
///   旧写入不能把后来出现的冲突盖成"已保存"，也不能把后来的编辑记成已保存。
/// - 这份的正文变了（文件在别处被改了，`follow`）：你没改过就当场跟上；你改着没写成的，留着你的字、说出文件变了，
///   由你选换成文件里的（`takeFile`）或留你的盖过它（`keepMine`）；选之前不再自动写。
@Observable
final class FileDraft {
    let file: LibraryFile
    @ObservationIgnored let handle = CardEditing.Handle()
    /// 编辑器里此刻的正文（不观察：每敲一个字都变，页面只看 `dirty` 与 `state`）。文件页挂上编辑器时载入它。
    @ObservationIgnored private(set) var body: String
    /// 技能的 name 与 description（输入框读写）；规则不用
    private(set) var name = ""
    private(set) var summary = ""
    /// 技能：照它合成整份、留着其余的键；规则为 nil
    @ObservationIgnored private var document: SkillDocument?
    @ObservationIgnored private var base: String
    /// 有没写进文件的字。
    private(set) var dirty = false
    /// 此刻一个字都没有（规则还没有文件，或清空了）：全局规则这时给起步规则（`StarterBar`）。
    private(set) var blank: Bool
    private(set) var state = State.idle
    /// 规则另写了一份时，正文换成合并稿、标出会并进来的段（`MergeBar` 点"合并进来"）；这时编辑器交出键盘、不接输入
    var previewing = DebugHooks.preset.mergePreview
    /// 合并时一并撤掉的替换基础提示的那几份（`TidyOrder.retire`）
    var retire: Set<InstructionSource.Origin> = []
    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private var autosave: Autosave?
    @ObservationIgnored private var epoch = 0
    /// 正在写的那一版：它的回声（同步来的、等于它的文件）是自己写的，不是别处的改动。
    @ObservationIgnored private var inflight: String?

    enum State: Equatable {
        case idle
        /// Mac 在存、手机在发
        case saving
        /// 刚写成（Mac 存好、手机那台写进去了）
        case saved
        /// 文件在别处被改了，已换成它
        case followed
        /// 文件在别处被改了，而你改着的还没写成：`file` 是文件此刻的样子（还没同步来时为 nil）
        case conflict(file: String?)
        case failed
    }

    /// 文件在别处改过、等你选（这时不自动写，纸飞机也不亮）。
    var conflicted: Bool { if case .conflict = state { true } else { false } }

    /// 整份文件此刻的样子（技能是合成的 SKILL.md）。
    var text: String { document.map { $0.with(name: name, description: summary, body: body) } ?? body }

    init(_ file: LibraryFile, text: String?, workspace: Workspace) {
        self.file = file
        base = text ?? ""
        body = ""
        self.workspace = workspace
        blank = Self.isBlank(base)
        load(base)
        #if os(macOS)
        // 写不成的错已在 `write` 里提示，这里不再报
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

    /// 把一篇现成的正文填进编辑器（起步规则）：同你自己打的字一样算改动、一样存。
    func fill(_ text: String) {
        handle.replace(text)
        changed(body: text)
    }

    private func edited() {
        mark()
        if case .conflict = state { return }
        autosave?.changed(text)
    }

    /// 写进那台 Mac（Mac 的自动存、手机的"发往 Mac"）：带上改之前看到的那一版。
    func send() async { try? await write(text) }

    /// 写不成抛错（已提示、状态已记 `failed`），自动存据此把这一版留在待写里，离开时再试。
    private func write(_ text: String) async throws {
        // 只写此刻的这一版：换成文件里的之后，早先排着的那一版不算数
        guard let library = workspace.library, text == self.text, text != base else { return }
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
            // 写的期间又打了字：这一版写成了，但文件页上的还没写
            state = dirty ? .idle : .saved
        } catch AgentLibraryError.changedOnMac {
            guard epoch == mine else { return }
            drop()
            // 文件此刻的样子随它那一条同步来（`follow`）
            state = .conflict(file: nil)
        } catch {
            workspace.fail(error)
            guard epoch == mine else { return }
            state = .failed
            throw error
        }
    }

    /// 丢下排着的和在途的：换代次，在途的写完时不再改任何东西。
    private func drop() {
        epoch += 1
        autosave?.discard()
    }

    /// 这份同步来的正文变了（`LibraryFileText`，对上了快照的哈希）：是自己写成的那一版就只记下；你没改过就跟上；改着的留着，说出文件变了。
    /// 在冲突里：文件变得和我的字一样，就是已保存；文件回到了基准（别处改回去了），没有别处的改动要选了，有没写的字照常自动存。
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
            // 你选之前不写：还没写的那一版留着，不在背后带着新基准盖过文件
            drop()
            state = .conflict(file: file)
        } else {
            replace(with: file)
        }
    }

    /// 文件在别处改过、你也改着：丢下你的，换成文件此刻的样子。
    func takeFile() {
        guard case .conflict(let file?) = state else { return }
        replace(with: file)
    }

    /// 文件在别处改过、你也改着：留你的，盖过文件此刻的样子（以它为基准再写一次）。
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

    /// 拆开一份文件：技能拆出 name、description 与正文，规则整份是正文。
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

    /// 页顶次要一行里写的存好没有（Mac 自动存，手机发往 Mac）；文件在别处改过、等你选时不写，文件页顶上那一条写（`ConflictBar`）。
    var shownState: String? { Self.shown(state, dirty: dirty) }

    /// 最长的那个（页顶按它留宽，换字时不伸缩）。
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

    /// "已保存"、"已跟上"亮一会儿就收（页面 `.task(id: draft?.state)` 里调，机制见 `SaveState.linger`）。
    func settleSoon() async {
        guard state == .saved || state == .followed else { return }
        #if os(iOS)
        let awaitsMac = true
        #else
        let awaitsMac = false
        #endif
        if await SaveState.linger(awaitsMac: awaitsMac) { state = .idle }
    }

    /// 离开文件页：Mac 写下没存的字。
    func leave() async {
        // 写不成的错已在 `write` 里提示
        try? await autosave?.flush()
    }
}
