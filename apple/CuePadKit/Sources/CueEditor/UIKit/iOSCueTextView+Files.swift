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
        // 文字（含存储格式的附件引用）按文字收；图片取图片；别的都当文件收
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            importFile(from: provider, type: .image, into: item)
        } else if provider.canLoadObject(ofClass: NSString.self) {
            // 文本一律按存储格式解析：附件引用还原成附件
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                nonisolated(unsafe) let item = item
                let text = object as? String
                Task { @MainActor in
                    guard let self, let text else { return item.setNoResult() }
                    item.setResult(attributedString: self.core.attributed(CueFormat.parse(text)))
                }
            }
        } else if let type = provider.registeredContentTypes.first {
            importFile(from: provider, type: type, into: item)
        } else {
            item.setNoResult()
        }
    }

    /// 取文件表示（系统给的临时副本，回调里拷走），存好后把附件交回粘贴项；图片只有对象没有文件时转 PNG。
    private func importFile(from provider: NSItemProvider, type: UTType, into item: UITextPasteItem) {
        let files = files
        nonisolated(unsafe) let item = item, provider = provider
        let finish: @Sendable (Result<(key: String, name: String), any Error>) -> Void = { result in
            Task { @MainActor [weak self] in
                guard let self else { return item.setNoResult() }
                switch result {
                case .success(let stored): item.setResult(attributedString: core.onOwnLine(core.attachmentString(key: stored.key, name: stored.name), replacing: selectedRange))
                case .failure(let error):
                    onError?(error)
                    item.setNoResult()
                }
            }
        }
        provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, fileError in
            if let url {
                // 临时副本的名字是系统起的，显示用分享方给的名字
                let name = provider.suggestedName.map { $0 + ((url.pathExtension.isEmpty || $0.hasSuffix("." + url.pathExtension)) ? "" : "." + url.pathExtension) }
                finish(Result { (try files.store(fileAt: url), name ?? url.lastPathComponent) })
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                _ = provider.loadObject(ofClass: UIImage.self) { object, objectError in
                    guard let png = (object as? UIImage)?.pngData() else { return finish(.failure(objectError ?? fileError ?? CocoaError(.fileReadUnknown))) }
                    finish(Result { (try files.store(png), "") })
                }
            } else {
                finish(.failure(fileError ?? CocoaError(.fileReadUnknown)))
            }
        }
    }

    // MARK: 外部选择器

    /// 相册选来的图片：在光标处插入。
    public func insertImage(data: Data) {
        insert([.data(data)])
    }

    /// 文件选择器选来的文件（安全作用域的访问在这里拿、存好后放开）：在光标处插入。
    public func insertFiles(_ urls: [URL]) {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        insert(urls.map(IncomingFile.file)) { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    }

    /// 存好（后台）再插到此刻的光标处，光标落在后面。
    private func insert(_ files: [IncomingFile], done: @escaping @MainActor () -> Void = {}) {
        core.importFiles(files) { [weak self] result in
            done()
            guard let self else { return }
            switch result {
            case .success(let insertion):
                let lined = core.onOwnLine(insertion, replacing: selectedRange)
                replace(selectedRange, with: lined, caret: selectedRange.location + lined.length)
            case .failure(let error): onError?(error)
            }
        }
    }

    // MARK: 点附件

    /// 点按落在哪个附件上（字符位置的附件，且点在它的框里）。
    func attachment(at point: CGPoint) -> (key: String, name: String, file: URL?)? {
        guard let position = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        for index in [offset, offset - 1] {
            guard let hit = core.attachment(at: index),
                  let start = self.position(from: beginningOfDocument, offset: index),
                  let end = self.position(from: start, offset: 1),
                  let range = textRange(from: start, to: end),
                  firstRect(for: range).contains(point)
            else { continue }
            return hit
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
        if let file = hit.file {
            QuickLook.show(file, title: hit.name, from: self)
        } else {
            onFetchFile?(hit.key)
        }
    }

    // MARK: 复制

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
