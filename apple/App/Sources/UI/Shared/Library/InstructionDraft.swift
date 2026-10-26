import CueStore
import Foundation

/// 一份说明此刻的编辑（Mac 的说明编辑页、手机的说明页同一份）：编辑器是正文的唯一写者，文件是事实。
/// - `base` 是编辑器以为文件此刻的样子（打开时读到的、自己写成的、跟上的那一版）；写入都带它的哈希（`InstructionEdit.base`），
///   文件已不是它，那台 Mac 就不写（`AgentLibraryError.changedOnMac`）。
/// - Mac 自动存（停手一小会儿，同灵感的编辑页，`Autosave`），没有保存钮；手机攒着，点纸飞机"发往 Mac"（`send`）。
/// - 快照里的这份变了（文件在别处被改了，`follow`）：你没改过就当场跟上；你改着没写成的，留着你的字、说出文件变了，由你选换成文件里的（`takeFile`）。
@Observable
final class InstructionDraft {
    let kind: LibraryInstruction.Kind
    @ObservationIgnored let handle = CardEditing.Handle()
    /// 编辑器里此刻的正文（不观察：每敲一个字都变，页面只看 `dirty` 与 `state`）。编辑页挂上编辑器时载入它。
    @ObservationIgnored private(set) var text: String
    @ObservationIgnored private var base: String
    /// 有没写进文件的字。
    private(set) var dirty = false
    private(set) var state = State.idle
    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private var autosave: Autosave?

    enum State: Equatable {
        case idle
        /// Mac 在存、手机在发
        case saving
        /// 刚写成（Mac 存好、手机那台写进去了）
        case saved
        /// 文件在别处被改了，编辑器已换成它
        case followed
        /// 文件在别处被改了，而你改着的还没写成：`file` 是文件此刻的样子（还没同步来时为 nil）
        case conflict(file: String?)
        case failed
    }

    init(_ instruction: LibraryInstruction, workspace: Workspace) {
        kind = instruction.kind
        text = instruction.text ?? ""
        base = text
        self.workspace = workspace
        #if os(macOS)
        autosave = Autosave(save: { [weak self] text in await self?.write(text) }, onError: { _ in })
        #endif
    }

    func changed(_ next: String) {
        text = next
        mark()
        if case .conflict = state { return }
        autosave?.changed(next)
    }

    /// 写进那台 Mac（Mac 的自动存、手机的"发往 Mac"）：带上改之前看到的那一版。
    func send() async { await write(text) }

    private func write(_ text: String) async {
        guard let library = workspace.library, text != base else { return }
        state = .saving
        do {
            try await workspace.saveInstruction(InstructionEdit(instruction: kind, base: LibraryInstruction.base(of: base), text: text), in: library)
            base = text
            mark()
            state = .saved
        } catch AgentLibraryError.changedOnMac {
            state = .conflict(file: workspace.library?.instruction(kind)?.text)
        } catch {
            state = .failed
            workspace.fail(error)
        }
    }

    /// 快照里这份的正文变了：是自己写成的那一版就只记下；你没改过就跟上；改着的留着，说出文件变了。
    func follow(_ file: String?) {
        let file = file ?? ""
        guard file != base else { return }
        if file == text {
            base = file
            mark()
            return
        }
        if dirty {
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

    private func replace(with file: String) {
        base = file
        text = file
        handle.replace(file)
        mark()
        state = .followed
    }

    private func mark() { if dirty != (text != base) { dirty = text != base } }

    /// "已保存"、"已跟上"亮一会儿就收。
    func settle() { if state == .saved || state == .followed { state = .idle } }

    /// 离开编辑页：Mac 写下没存的字。
    func leave() async { await autosave?.flush() }
}
