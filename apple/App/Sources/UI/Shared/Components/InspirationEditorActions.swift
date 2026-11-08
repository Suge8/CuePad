import CueStore
import CueText
import SwiftUI

/// 两端灵感编辑页的更多菜单。分享在点击时读取编辑器正文与变量快照，系统消费结束前持有文件。
struct InspirationEditorActions: View {
    let card: Card
    let editing: CardEditing
    @Binding var payload: InspirationPayload?
    @Binding var request: InspirationShareRequest?
    var body: some View {
        Group {
            Group {
                Button("排成图片分享") { share(originals: false) }
                Button("分享原图") { share(originals: true) }
                Button("分享文字") {
                    payload = InspirationPayload(files: nil, urls: [], text: CueFormat.plainText(Outgoing.text(body: latestText, values: card.variableValues)))
                }
            }.disabled(editing.text.isEmpty)
            Divider()
            CardActions(card: card, more: true).labelStyle(.titleAndIcon)
        }
    }

    private var latestText: String { editing.handle.text ?? editing.text }

    private func share(originals: Bool) {
        request = InspirationShareRequest(source: CueVariables.fill(latestText, values: card.variableValues), originals: originals)
    }
}

struct InspirationShareRequest: Identifiable {
    let id = UUID()
    let source: String
    let originals: Bool
}

/// 准备过程与系统分享由页面持有；导航栏里的菜单会重建，不能持有异步结果或弹层生命周期。
struct InspirationSharePresentation: ViewModifier {
    @Binding var request: InspirationShareRequest?
    @Binding var payload: InspirationPayload?
    let editing: CardEditing?

    func body(content: Content) -> some View {
        content
            .background(InspirationSystemShare(payload: $payload))
            .panel(item: $request, style: .bubble(.unanchored)) { snapshot in
                InspirationExport(source: snapshot.source, originals: snapshot.originals, close: { request = nil }, recover: recover) { result in
                    request = nil
                    payload = result
                }
            }
    }

    private func recover(_ action: InspirationShare.Recovery) {
        request = nil
        if action == .edit { editing?.handle.focus() }
    }
}
