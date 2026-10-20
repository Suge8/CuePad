#if canImport(AppKit)
import AppKit
import CueText

extension CueTextView {
    // MARK: 粘贴与拖入
    // 粘贴（paste:）和拖入最终都汇到 readSelection(from:type:)，在这里统一处理。

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let images = pboard.images
        if !images.isEmpty { return insert(images) }
        // 文本一律按存储格式解析：图片标记还原成附件
        guard let text = pboard.string(forType: .string) else { return false }
        insertText(core.attributed(CueFormat.parse(text)), replacementRange: selectedRange())
        return true
    }

    private func insert(_ images: [PasteboardImage]) -> Bool {
        do {
            let insertion = NSMutableAttributedString()
            for image in images {
                let id = switch image {
                case .file(let url): try imageStore.store(fileAt: url)
                case .png(let data): try imageStore.store(data)
                }
                insertion.append(core.imageString(id: id))
            }
            insertText(insertion, replacementRange: selectedRange())
            return true
        } catch {
            onError?(error)
            return false
        }
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let images = sender.draggingPasteboard.images
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return insert(images)
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        NSPasteboard.imageTypes + super.readablePasteboardTypes
    }

    public override func preferredPasteboardType(
        from availableTypes: [NSPasteboard.PasteboardType], restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?
    ) -> NSPasteboard.PasteboardType? {
        (NSPasteboard.imageTypes + [.string]).first { availableTypes.contains($0) }
            ?? super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
    }

    // MARK: 复制

    /// 复制/剪切/拖出选区一律输出存储格式字符串：附件不会被归档成 RTFD 而丢失图片 id。
    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(CueFormat.serialize(core.tokens(in: range)), forType: .string)
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        type == .string && writeSelection(to: pboard, types: [type])
    }

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}
#endif
