import CueEditor
import CueStore
import CueSync
import CueText
import Foundation

/// 记录先到、文件后到：手机上大文件、按流量计费时不自动取，点一下才取。
nonisolated enum FileStatus {
    private static func kind(of name: String) -> String {
        PreviewKind(fileName: name)?.label ?? AttachmentKey.format(ofName: name).uppercased().nonEmpty ?? String(localized: "文件")
    }

    /// 只有附件停着，别的照常同步。
    static var overQuota: String { String(localized: "iCloud 空间已满：附件先留在这台，腾出空间后接着传") }

    private static func size(of file: URL) -> String? {
        guard let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return bytes.formatted(.byteCount(style: .file))
    }

    static func line(name: String, file: URL?, transfer: FileTransfer?) -> CueFileStatus {
        let kind = name.isEmpty ? nil : kind(of: name)
        if let transfer {
            let percent = transfer.fraction.formatted(.percent.precision(.fractionLength(0)))
            let doing = transfer.direction == .upload ? String(localized: "上传中 \(percent)") : String(localized: "下载中 \(percent)")
            return CueFileStatus(detail: Dotted(kind, doing).visible, progress: transfer.fraction)
        }
        guard let file else { return CueFileStatus(detail: Dotted(kind, String(localized: "点一下从 iCloud 取")).visible) }
        return CueFileStatus(detail: Dotted(kind, size(of: file)).visible)
    }
}
