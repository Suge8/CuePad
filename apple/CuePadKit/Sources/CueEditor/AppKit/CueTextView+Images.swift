#if canImport(AppKit)
import AppKit
import CueText
import UniformTypeIdentifiers

extension CueTextView {
    // MARK: 粘贴与拖入
    // 粘贴（paste:）和拖入最终都汇到 readSelection(from:type:)，在这里统一处理。

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        do {
            let ids = try importImages(from: pboard)
            if !ids.isEmpty {
                let insertion = NSMutableAttributedString()
                ids.forEach { insertion.append(imageString(id: $0)) }
                insertText(insertion, replacementRange: selectedRange())
                return true
            }
        } catch {
            onError?(error)
            return false
        }
        // 文本一律按存储格式解析：分隔线行与图片标记还原成控件
        guard let text = pboard.string(forType: .string) else { return false }
        insertText(attributed(CueFormat.parse(text)), replacementRange: selectedRange())
        return true
    }

    private static let imageURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingContentsConformToTypes: [UTType.image.identifier]
    ]

    private func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.imageURLOptions)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private func importImages(from pasteboard: NSPasteboard) throws -> [String] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: Self.imageURLOptions) as? [URL], !urls.isEmpty {
            return try urls.map { try imageStore.store(fileAt: $0) }
        }
        if let png = pasteboard.data(forType: .png) { return [try imageStore.store(png)] }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [try imageStore.store(png)]
        }
        return []
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard containsImage(pasteboard) else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return readSelection(from: pasteboard, type: .fileURL)
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff, .fileURL] + super.readablePasteboardTypes
    }

    public override func preferredPasteboardType(
        from availableTypes: [NSPasteboard.PasteboardType], restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?
    ) -> NSPasteboard.PasteboardType? {
        [.png, .tiff, .fileURL, .string].first { availableTypes.contains($0) }
            ?? super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
    }

    /// 缩略图解码完成后重绘引用它的附件。只给视图打重绘标记没用：TextKit 缓存了片段的渲染结果，
    /// 必须让对应片段失效重排。
    func redrawImages(at url: URL) {
        let storage = textStorage!
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let image = value as? CueImageAttachment, image.fileURL == url, let target = textRange(range) else { return }
            textLayoutManager?.invalidateLayout(for: target)
        }
        needsLayout = true
    }

    // MARK: 复制

    /// 复制/剪切/拖出选区一律输出存储格式字符串：附件不会被归档成 RTFD 而丢失图片 id。
    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(CueFormat.serialize(tokens(in: range)), forType: .string)
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        type == .string && writeSelection(to: pboard, types: [type])
    }

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}
#endif
