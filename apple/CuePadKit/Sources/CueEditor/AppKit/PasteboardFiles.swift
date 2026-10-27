#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

extension NSPasteboard {
    /// 文本视图把粘贴、拖入当附件收时，要排在 `readablePasteboardTypes` 前面的种类（菜单的"粘贴"按它判断能不能用）。
    public static let fileTypes: [PasteboardType] = [.png, .tiff, .fileURL]

    /// 这里的附件，粘贴与拖入共用这一条规则（卡片编辑器与输入框都是）：有文件时就是这几个文件（任意类型，文件夹不收）——访达复制文件还附带
    /// 一张文件图标的 TIFF，不能把图标当图收；没有文件时取图片字节，只有 TIFF 的（浏览器复制的图）转成 PNG。
    public var files: [IncomingFile] {
        if availableType(from: [.fileURL]) != nil {
            let urls = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }.map(IncomingFile.file)
        }
        if let png = data(forType: .png) { return [.data(png)] }
        if let tiff = data(forType: .tiff), let png = ImageFiles.png(from: tiff) { return [.data(png)] }
        return []
    }
}
#endif
