import CueStore
import SwiftUI

/// 一条灵感或任务正文此刻的编辑：编辑器的操作口、打字中的正文、自动保存与保存状态。整页编辑（Mac 编辑页、手机纸页）与
/// 任务气泡里的正文（任务标题下面的话，`Card.rest`）共用这一份，各自只管怎么摆。编辑器是这段正文的唯一写者；
/// 离开时 `leave` 写下没保存的字，什么都没写的灵感不留下（新记的一条先建一条空的再编辑）。
/// 手机进入后台时由壳层等它落盘（之后 App 可能被系统结束，离开页面的 onDisappear 不会再来）。
@Observable
final class CardEditing {
    let cardID: UUID
    /// 打开那一刻的正文：编辑器只在创建时载入一次。
    let initialText: String
    @ObservationIgnored let handle = Handle()
    /// 打字中的正文（底栏据此认出变量）。
    private(set) var text: String
    private(set) var saveState = SaveState.idle
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored private var autosave: Autosave?
    #if os(iOS)
    @ObservationIgnored private var flushToken: UUID?
    #endif

    #if os(macOS)
    typealias Handle = EditorHandle
    #else
    typealias Handle = IOSEditorHandle
    #endif

    init(_ card: Card, part: CardTextPart = .whole, workspace: Workspace) {
        cardID = card.id
        initialText = part.text(of: card)
        text = initialText
        self.workspace = workspace
        let store = workspace.services.store, id = card.id
        let autosave = Autosave(
            save: { [weak self] text in
                self?.saveState = .saving
                try await store.updateCard(id) { part.write(text, into: &$0) }
                self?.saveState = .saved
            },
            onError: { [weak self] error in
                self?.saveState = .failed
                workspace.fail(error)
            })
        self.autosave = autosave
        #if os(iOS)
        flushToken = workspace.services.addBackgroundFlush { await autosave.flush() }
        #endif
    }

    func changed(_ next: String) {
        text = next
        autosave?.changed(next)
    }

    func settleSaved() { if saveState == .saved { saveState = .idle } }

    /// 写下没保存的字，再读库里此刻的这条（任务气泡的"开始"、编辑器里的 ⌘↩ 交给 Agent 的就是它）。
    func flushed() async throws -> Card? {
        await autosave?.flush()
        return try await workspace.services.store.card(cardID)
    }

    func leave() {
        workspace.leaveEditing(cardID, flush: autosave)
        #if os(iOS)
        if let flushToken { workspace.services.removeBackgroundFlush(flushToken) }
        flushToken = nil
        #endif
    }
}

/// 保存状态：平时不显示；保存中显示，保存完显示"已保存"一会儿，失败一直显示直到下次保存成功。
enum SaveState: Equatable {
    case idle, saving, saved, failed

    static let savedDisplay: Duration = .seconds(1.5)

    var text: String? {
        switch self {
        case .idle: nil
        case .saving: "保存中…"
        case .saved: "已保存"
        case .failed: "没能保存"
        }
    }
}
