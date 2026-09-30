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
    // MARK: 粘贴与拖入

    fileprivate func transform(_ item: UITextPasteItem) {
        let provider = item.itemProvider
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            importImage(from: provider) { [weak self] result in
                guard let self else { return item.setNoResult() }
                switch result {
                case .success(let id): item.setResult(attributedString: core.imageString(id: id))
                case .failure(let error):
                    onError?(error)
                    item.setNoResult()
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            // 文本一律按存储格式解析：分隔线行与图片标记还原成控件
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                nonisolated(unsafe) let item = item
                let text = object as? String
                Task { @MainActor in
                    guard let self, let text else { return item.setNoResult() }
                    item.setResult(attributedString: self.core.attributed(CueFormat.parse(text)))
                }
            }
        } else {
            item.setNoResult()
        }
    }

    /// 优先取文件表示（直接拷贝，不把整张图读进内存）；只有图片对象时转 PNG。回调在主线程。
    private func importImage(from provider: NSItemProvider, completion: @escaping @MainActor (Result<String, any Error>) -> Void) {
        let store = imageStore
        func finish(_ result: Result<String, any Error>) { Task { @MainActor in completion(result) } }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, fileError in
            if let url {
                finish(Result { try store.store(fileAt: url) })
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                _ = provider.loadObject(ofClass: UIImage.self) { object, objectError in
                    guard let png = (object as? UIImage)?.pngData() else { return finish(.failure(objectError ?? fileError ?? CocoaError(.fileReadUnknown))) }
                    finish(Result { try store.store(png) })
                }
            } else {
                finish(.failure(fileError ?? CocoaError(.fileReadUnknown)))
            }
        }
    }

    // MARK: 键盘工具栏的图片入口

    /// 外部选择器拿到图片后调用：在光标处插入。
    public func insertImage(data: Data) {
        insert(Result { try imageStore.store(data) })
    }

    public func insertImage(fileAt url: URL) {
        insert(Result { try imageStore.store(fileAt: url) })
    }

    private func insert(_ result: Result<String, any Error>) {
        switch result {
        case .success(let id): replace(selectedRange, with: core.imageString(id: id), caret: selectedRange.location + 1)
        case .failure(let error): onError?(error)
        }
    }

    // MARK: 复制

    /// 复制/剪切一律输出存储格式字符串：附件不会被归档成 RTFD 而丢失图片 id。
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
