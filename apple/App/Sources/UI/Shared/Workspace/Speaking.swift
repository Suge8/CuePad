import CueStore
import SwiftUI

/// 发消息只有这一条路（全 App 所有入口：会话回复框的说话、作答与斜杠命令，Cue 页与浮起的 Cue 输入条，菜单栏交给 Cue，
/// 手机发给 Agent，Mac 把提示词发给 Agent，压缩按钮）：
/// 按下发送 → 同步取走草稿、清空输入框（在任何 await 之前）→ 写一条记录（`Listener`）→ 后台立即上传。界面从不等上传或执行结果，
/// 到哪了只看记录（`Speech`）。只有写库本身失败时草稿放回输入框（期间新打的字接在后面）并提示。
/// 正文写不出（图片存不进图片库）时什么都没发：草稿原样留着、只提示原因；调用方看返回值，只有写出了才收起输入框、
/// 当作发出（`saying` 是写出后的那句提示，也只在写出时说，不盖掉报错）。
/// 写"说的话"的底层调用只在这里（源码检查 `lint.sh` 拦别处的）。
extension Workspace {
    /// 从输入框说出去：`box` 是输入框的草稿，`content` 把取走的草稿写成存储格式正文（图片在这里写进图片库；写不出时什么都不动、提示），
    /// `keeping` 是发出后输入框里留下的（斜杠命令留着批注跟下一句发）。返回写库与上传的那个任务（测试等它）；
    /// 正文写不出、什么都没发时为 nil。
    func speak(
        to listener: Listener, from box: Binding<ComposerDraft>, keeping: (ComposerDraft) -> ComposerDraft = { _ in ComposerDraft() },
        saying: Dotted? = nil, content: (ComposerDraft) throws -> String
    ) -> Task<Void, Never>? {
        let taken = box.wrappedValue
        let stored: String
        do {
            stored = try content(taken)
        } catch {
            fail(error)
            return nil
        }
        let kept = keeping(taken)
        box.wrappedValue = kept
        if let saying { say(saying) }
        return write(stored, to: listener) { box.wrappedValue = taken.followed(by: box.wrappedValue, keeping: kept) }
    }

    /// 不是从输入框说的（提示词、压缩按钮）：写不进库时只提示，原文还在原处。
    @discardableResult
    func speak(_ stored: String, to listener: Listener, saying: Dotted? = nil) -> Task<Void, Never> {
        if let saying { say(saying) }
        return write(stored, to: listener) {}
    }

    /// 重发一句没能送达的话：先撤回它（撤不回——Mac 已领取、Cue 已收到——就不重发，免得说两遍），再用同样的内容写一条新的。
    /// 撤回之后写不进库时，原文放进 `box`（这个去处的输入框），文字不丢。
    func resend(_ said: Said, restoringInto box: Binding<ComposerDraft>) {
        let services = services
        attempt {
            try await services.withdraw(said)
            await self.write(said.content, to: said.listener) {
                box.wrappedValue.append(stored: said.content, files: services.store.files)
            }.value
        }
    }

    /// 移除一句没能送达的话（同样先撤回）。
    func remove(_ said: Said) {
        let services = services
        attempt { try await services.withdraw(said) }
    }

    private func write(_ stored: String, to listener: Listener, restore: @escaping () -> Void) -> Task<Void, Never> {
        let services = services
        return Task {
            let id: UUID
            do {
                id = try await Self.record(stored, to: listener, in: services.store)
            } catch {
                restore()
                fail(error)
                return
            }
            await services.upload(id)
        }
    }

    private static func record(_ stored: String, to listener: Listener, in store: CueStore) async throws -> UUID {
        switch listener {
        case .cue:
            try await store.addCueMessage(.you, text: stored).id
        case .session(let target, let host, let mode, let card):
            try await store.requestDelivery(stored, to: target, on: host, mode: mode, card: card).id
        }
    }
}

extension ComposerDraft {
    /// 写库失败时放回输入框的草稿：取走的在前，期间新打的接在后面（文字空一行，图片、带上的卡片与批注依次接上、不重复）；
    /// 发出时就留在输入框里的（`kept`）本来就在取走的里，不算新打的。
    func followed(by later: ComposerDraft, keeping kept: ComposerDraft) -> ComposerDraft {
        var merged = self
        let typed = later.text == kept.text ? "" : later.text
        merged.text = [text, typed].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        merged.images += later.images.filter { image in !images.contains { $0.id == image.id } }
        merged.attachments += later.attachments.filter { outbox in !attachments.contains { $0.card == outbox.card && $0.content == outbox.content } }
        merged.notes += later.notes.filter { note in !notes.contains { $0.id == note.id } }
        return merged
    }
}
