#if canImport(UIKit)
import CueText
import UIKit
import UniformTypeIdentifiers

/// 粘贴与拖入共用 UITextPasteDelegate：UIKit 把拖入的条目也交给它转换，
/// 转换结果由 UITextView 插入并登记撤销。拖出选区一律输出存储格式字符串。
@MainActor
final class TransferDelegate: NSObject, UITextPasteDelegate, UITextDropDelegate, UITextDragDelegate {
    private weak var textView: CueTextView?

    init(textView: CueTextView) { self.textView = textView }

    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting, transform item: UITextPasteItem) {
        guard let textView else { return item.setNoResult() }
        textView.transform(item)
    }

    func textDraggableView(_ textDraggableView: any UIView & UITextDraggable, itemsForDrag dragRequest: any UITextDragRequest) -> [UIDragItem] {
        guard let textView else { return dragRequest.suggestedItems }
        let start = textView.offset(from: textView.beginningOfDocument, to: dragRequest.dragRange.start)
        let length = textView.offset(from: dragRequest.dragRange.start, to: dragRequest.dragRange.end)
        let text = CueFormat.serialize(textView.core.tokens(in: NSRange(location: start, length: length)))
        return [UIDragItem(itemProvider: NSItemProvider(object: text as NSString))]
    }

    func textDroppableView(_ textDroppableView: any UIView & UITextDroppable, proposalForDrop drop: any UITextDropRequest) -> UITextDropProposal {
        UITextDropProposal(operation: drop.isSameView ? .move : .copy)
    }
}

extension CueTextView {
    fileprivate func transform(_ item: UITextPasteItem) {
        let pasted = PastedItem(item.itemProvider)
        if pasted.isFile {
            nonisolated(unsafe) let item = item
            return core.importFiles([.pasted(pasted)], at: selectedRange, selection: { [weak self] in self?.selectedRange ?? NSRange(location: 0, length: 0) }) { [weak self] result in
                guard let self else { return item.setNoResult() }
                switch result {
                case .success((let insertion, let range)?): item.setResult(attributedString: core.onOwnLine(insertion, replacing: range))
                case .success(nil): item.setNoResult()
                case .failure(let error):
                    onError?(error)
                    item.setNoResult()
                }
            }
        }
        // 文本一律按存储格式解析：附件引用还原成附件
        guard item.itemProvider.canLoadObject(ofClass: NSString.self) else { return item.setNoResult() }
        _ = item.itemProvider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            nonisolated(unsafe) let item = item
            let text = object as? String
            Task { @MainActor in
                guard let self, let text else { return item.setNoResult() }
                item.setResult(attributedString: self.core.attributed(CueFormat.parse(text)))
            }
        }
    }

    /// 相册、文件选择器选来的：存好（后台）再插到此刻的光标处，光标落在后面。
    public func insert(_ files: [IncomingFile]) {
        core.importFiles(files, at: selectedRange, selection: { [weak self] in self?.selectedRange ?? NSRange(location: 0, length: 0) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((let insertion, let range)?):
                let lined = core.onOwnLine(insertion, replacing: range)
                replace(range, with: lined, caret: range.location + lined.length)
            case .success(nil): break
            case .failure(let error): onError?(error)
            }
        }
    }

    /// 点按落在哪个附件上（字符位置的附件，且点在它的框里）。
    func attachment(at point: CGPoint) -> (key: String, name: String, file: URL?, rect: CGRect)? {
        guard let position = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        for index in [offset, offset - 1] {
            guard let hit = core.attachment(at: index),
                  let start = self.position(from: beginningOfDocument, offset: index),
                  let end = self.position(from: start, offset: 1),
                  let range = textRange(from: start, to: end)
            else { continue }
            let rect = firstRect(for: range)
            if rect.contains(point) { return (hit.key, hit.name, hit.file, rect) }
        }
        return nil
    }

    /// 点中的是文件牌或还没到的图片（本机的图片照常定光标）。
    func opensAttachment(at point: CGPoint) -> Bool {
        guard let hit = attachment(at: point) else { return false }
        return hit.file == nil || !hit.name.isEmpty
    }

    @objc func tappedAttachment(_ tap: UITapGestureRecognizer) {
        guard let hit = attachment(at: tap.location(in: self)) else { return }
        onOpenAttachment?(hit.key, hit.name, FileChip.picture(in: hit.rect, named: hit.name))
    }

    /// 复制/剪切一律输出存储格式字符串：附件不会被归档成 RTFD 而丢失键。
    public override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0 else { return }
        pasteboard.string = CueFormat.serialize(core.tokens(in: range))
    }

    public override func cut(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0 else { return }
        copy(sender)
        replace(range, with: NSAttributedString(), caret: range.location)
    }
}
#endif
