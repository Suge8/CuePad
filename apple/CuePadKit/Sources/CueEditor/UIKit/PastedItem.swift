#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// 手机上粘贴、拖入的一个条目当附件收的规则，卡片编辑器与输入框共用这一处：图片、带文件网址的（文件 App 复制的文件）收作附件；
/// 有文字表示的（文字、网页链接、富文本）按文字收；别的有内容的（只给数据的任意文件）也收作附件。只看种类不读内容，不触发读取剪贴板的提示。
/// 系统的 `hasImages` 不认只有 HEIC 的剪贴板，不用它。
public struct PastedItem: @unchecked Sendable {
    // NSItemProvider 的读取接口可在任意线程调用、回调本就是 @Sendable；它只是没标 Sendable
    let provider: NSItemProvider

    public init(_ provider: NSItemProvider) { self.provider = provider }

    /// 这些种类（一个条目的，或整个剪贴板的）当附件收。
    public static func isFile(_ types: [UTType]) -> Bool {
        if types.contains(where: { $0.conforms(to: .image) || $0.conforms(to: .fileURL) }) { return true }
        return !types.contains { $0.conforms(to: .text) || $0.conforms(to: .url) } && types.contains { $0.conforms(to: .data) }
    }

    public var isFile: Bool { Self.isFile(provider.registeredContentTypes) }

    /// 剪贴板里当附件收的条目。
    public static func files(on pasteboard: UIPasteboard) -> [IncomingFile] {
        pasteboard.itemProviders.map(PastedItem.init).filter(\.isFile).map(IncomingFile.pasted)
    }

    /// 取出来存进附件目录。带文件网址的从网址拿原文件、名字是原文件名；别的取文件表示（系统给的是它起名的临时副本，名字用分享方给的），
    /// 图片只有对象没有文件时转 PNG。
    func store(in files: any CueFileStore) async throws -> (key: String, name: String) {
        let types = provider.registeredContentTypes
        if !types.contains(where: { $0.conforms(to: .image) }), types.contains(where: { $0.conforms(to: .fileURL) }), let url = await linkedFile() {
            return try await IncomingFile.file(url).store(in: files)
        }
        let type = types.first { $0.conforms(to: .image) } ?? types.first { $0.conforms(to: .data) } ?? .data
        return try await withCheckedThrowingContinuation { continuation in
            let item = self, suggested = provider.suggestedName
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, fileError in
                if let url {
                    let ext = url.pathExtension
                    let name = suggested.map { ext.isEmpty || $0.lowercased().hasSuffix("." + ext.lowercased()) ? $0 : $0 + "." + ext }
                    continuation.resume(with: Result { (try files.store(fileAt: url), name ?? url.lastPathComponent) })
                } else if item.provider.canLoadObject(ofClass: UIImage.self) {
                    _ = item.provider.loadObject(ofClass: UIImage.self) { object, objectError in
                        guard let png = (object as? UIImage)?.pngData() else {
                            return continuation.resume(throwing: objectError ?? fileError ?? CocoaError(.fileReadUnknown))
                        }
                        continuation.resume(with: Result { (try files.store(png), "") })
                    }
                } else {
                    continuation.resume(throwing: fileError ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    /// 条目里的文件网址；拿不到或不是文件为 nil（就取文件表示）。
    private func linkedFile() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }
}
#endif
