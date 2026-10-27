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
        // 图片与文件（带文件网址的，文字能从网址读出来，要先认）当附件收；文字（含存储格式的附件引用）按文字收；别的有内容的也当文件收
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            importFile(from: provider, type: .image, into: item)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            importLinkedFile(from: provider, into: item)
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
        } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }) {
            importFile(from: provider, type: type, into: item)
        } else {
            item.setNoResult()
        }
    }

    /// 带文件网址的（文件 App、访达拖来的）：从网址拿原文件，名字是原文件名；拿不到网址时同别的文件取文件表示。
    private func importLinkedFile(from provider: NSItemProvider, into item: UITextPasteItem) {
        let files = files
        nonisolated(unsafe) let item = item, provider = provider
        let finish = delivery(to: item)
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let url, url.isFileURL else {
                Task { @MainActor in
                    self?.importFile(from: provider, type: provider.registeredContentTypes.first { $0.conforms(to: .data) } ?? .data, into: item)
                }
                return
            }
            finish(Result { try IncomingFile.file(url).store(in: files) })
        }
    }

    /// 取文件表示（回调里存进附件目录），存好后把附件交回粘贴项；图片只有对象没有文件时转 PNG。
    private func importFile(from provider: NSItemProvider, type: UTType, into item: UITextPasteItem) {
        let files = files
        nonisolated(unsafe) let provider = provider
        let finish = delivery(to: item)
        // 系统给的是它起名的临时副本：名字用分享方给的
        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, fileError in
            if let url {
                let ext = url.pathExtension
                let suggested = provider.suggestedName.map { ext.isEmpty || $0.lowercased().hasSuffix("." + ext.lowercased()) ? $0 : $0 + "." + ext }
                finish(Result { (try files.store(fileAt: url), suggested ?? url.lastPathComponent) })
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

    /// 存好的附件交回粘贴项（自成一行）；存不进报错、不插。
    private func delivery(to item: UITextPasteItem) -> @Sendable (Result<(key: String, name: String), any Error>) -> Void {
        nonisolated(unsafe) let item = item
        return { [weak self] result in
            Task { @MainActor in
                guard let self else { return item.setNoResult() }
                switch result {
                case .success(let stored):
                    item.setResult(attributedString: self.core.onOwnLine(self.core.attachmentString(key: stored.key, name: stored.name), replacing: self.selectedRange))
                case .failure(let error):
                    self.onError?(error)
                    item.setNoResult()
                }
            }
        }
    }

    // MARK: 外部选择器

    /// 相册、文件选择器选来的：存好（后台）再插到此刻的光标处，光标落在后面。
    public func insert(_ files: [IncomingFile]) {
        core.importFiles(files) { [weak self] result in
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
