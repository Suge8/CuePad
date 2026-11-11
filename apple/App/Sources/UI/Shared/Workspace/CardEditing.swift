import CueStore
import CueText
import SwiftUI

/// 整页编辑与任务气泡（标题是首段、同一个编辑器写，`titled`）共用这一份，各自只管怎么摆。编辑器是这段正文的唯一写者。
/// 手机进入后台时由壳层等它落盘（之后 App 可能被系统结束，离开页面的 onDisappear 不会再来）。
@Observable
final class CardEditing {
    let cardID: UUID
    let initialText: String
    @ObservationIgnored let handle = Handle()
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

    init(_ card: Card, titled: Bool = false, workspace: Workspace) {
        cardID = card.id
        let unsaved = workspace.unsavedBodies[card.id]
        var restored = unsaved?.text
        if let found = unsaved, let base = found.base, card.body != base {
            restored = [card.body, found.text].joined(separator: "\n\n")
            workspace.say(Dotted(String(localized: "这条在别处改过，没能保存的字接在了后面")), tone: .failure)
        }
        initialText = restored ?? (titled && card.rest == nil ? CueLines.split(card.body).title + "\n" : card.body)
        text = initialText
        self.workspace = workspace
        let store = workspace.services.store, id = card.id
        let autosave = Autosave(
            save: { [weak self] text in
                self?.saveState = .saving
                do {
                    try await store.updateCard(id) { $0.body = text }
                } catch {
                    self?.saveState = .failed
                    throw error
                }
                self?.saveState = .saved
                workspace.unsavedBodies[id] = nil
            },
            onError: { workspace.fail($0) })
        self.autosave = autosave
        if unsaved != nil { autosave.changed(initialText) }
        #if os(iOS)
        flushToken = workspace.services.addBackgroundFlush {
            do { try await autosave.flush() } catch { workspace.fail(error) }
        }
        #endif
    }

    #if os(iOS)
    // 登记的落盘闭包攥着自动存与工作区：没走 `leave` 就被放掉（窗口场景直接销毁）时，在这里注销，不然服务一直攥着它们
    isolated deinit {
        if let flushToken { workspace.services.removeBackgroundFlush(flushToken) }
    }
    #endif

    var hasVariables: Bool { !CueVariables.names(in: text).isEmpty }

    func changed(_ next: String) {
        text = next
        autosave?.changed(next)
    }

    func settleSaved() { if saveState == .saved { saveState = .idle } }

    func flushed() async throws -> Card? {
        try await autosave?.flush()
        return try await workspace.services.store.card(cardID)
    }

    func leave() {
        workspace.leaveEditing(cardID, flush: autosave, heading: CueSummary.title(of: initialText))
        #if os(iOS)
        if let flushToken { workspace.services.removeBackgroundFlush(flushToken) }
        flushToken = nil
        #endif
    }
}

enum SaveState: Equatable {
    case idle, saving, saved, failed

    private static let savedDisplay: Duration = .seconds(1.5)

    /// 等够返回 true；等的时候状态又变了（任务取消）返回 false。
    /// `awaitsMac`：手机"发往 Mac"是等那台回话，结果晚到，多亮一倍的时间让人看见；Mac 自动存立刻有结果。
    static func linger(awaitsMac: Bool = false) async -> Bool {
        try? await Task.sleep(for: savedDisplay * (awaitsMac ? 2 : 1))
        return !Task.isCancelled
    }

    static var longestText: String { [saving, saved, failed].compactMap(\.text).max { $0.count < $1.count } ?? "" }

    var text: String? {
        switch self {
        case .idle: nil
        case .saving: String(localized: "保存中…")
        case .saved: String(localized: "已保存")
        case .failed: String(localized: "没能保存")
        }
    }
}
