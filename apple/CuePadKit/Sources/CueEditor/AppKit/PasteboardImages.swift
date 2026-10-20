#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

/// 剪贴板或拖入里的一张图：访达复制、拖入的图片文件按文件给（接收方直接拷文件，不必整张读进内存），截图、浏览器复制的图按 PNG 字节给。
public enum PasteboardImage {
    case file(URL)
    case png(Data)

    /// 原图字节（文件的读出来）。
    public func data() throws -> Data {
        switch self {
        case .file(let url): try Data(contentsOf: url)
        case .png(let data): data
        }
    }
}

extension NSPasteboard {
    /// 文本视图把粘贴、拖入当图片收时，要排在 `readablePasteboardTypes` 前面的种类（菜单的"粘贴"按它判断能不能用）。
    public static let imageTypes: [PasteboardType] = [.png, .tiff, .fileURL]

    /// 这里的图片，粘贴与拖入共用这一条规则（卡片编辑器与输入框都是）：有文件时只认其中的图片文件——访达复制任何文件都附带一张
    /// 文件图标的 TIFF，复制的不是图片时不能把图标当图收；没有文件时取图片字节，只有 TIFF 的（浏览器复制的图）转成 PNG。
    public var images: [PasteboardImage] {
        if availableType(from: [.fileURL]) != nil {
            let urls = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }.map(PasteboardImage.file)
        }
        if let png = data(forType: .png) { return [.png(png)] }
        if let tiff = data(forType: .tiff), let png = ImageFiles.png(from: tiff) { return [.png(png)] }
        return []
    }
}
#endif
