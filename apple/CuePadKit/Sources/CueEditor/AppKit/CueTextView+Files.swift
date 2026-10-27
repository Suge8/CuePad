#if canImport(AppKit)
import AppKit
import CueText

extension CueTextView {
    // MARK: 粘贴与拖入
    // 粘贴（paste:）和拖入最终都汇到 readSelection(from:type:)，在这里统一处理。

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let files = pboard.files
        if !files.isEmpty {
            insert(files)
            return true
        }
        // 文本一律按存储格式解析：附件引用还原成附件
        guard let text = pboard.string(forType: .string) else { return false }
        insertText(core.attributed(CueFormat.parse(text)), replacementRange: selectedRange())
        return true
    }

    /// 存好（后台）再插到此刻的光标处。
    func insert(_ files: [IncomingFile]) {
        core.importFiles(files) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let insertion): insertText(core.onOwnLine(insertion, replacing: selectedRange()), replacementRange: selectedRange())
            case .failure(let error): onError?(error)
            }
        }
    }

    /// 选文件面板选来的文件（"插入文件…"）插到光标处。
    public func insertFiles(_ urls: [URL]) {
        insert(urls.map(IncomingFile.file))
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = sender.draggingPasteboard.files
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        insert(files)
        return true
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        NSPasteboard.fileTypes + super.readablePasteboardTypes
    }

    @objc func chooseFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // 非模态：不把主线程关进面板的嵌套事件循环
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.insertFiles(urls) }
        }
    }

    // MARK: 点附件

    /// 点在附件上（不移光标）：文件牌在本机就快速查看，还没到这台的文件牌、图片交给宿主去取；本机的图片与别处照常。
    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let hit = attachment(at: event) else { return super.mouseDown(with: event) }
        if let file = hit.file {
            guard !hit.name.isEmpty else { return super.mouseDown(with: event) }
            QuickLook.show(file, title: hit.name)
        } else {
            onFetchFile?(hit.key)
        }
    }

    private func attachment(at event: NSEvent) -> (key: String, name: String, file: URL?)? {
        guard let window else { return nil }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        for candidate in [index, index - 1] {
            guard let hit = core.attachment(at: candidate) else { continue }
            if firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil).contains(screen) { return hit }
        }
        return nil
    }

    // MARK: 复制

    /// 复制/剪切/拖出选区一律输出存储格式字符串：附件不会被归档成 RTFD 而丢失键。
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
