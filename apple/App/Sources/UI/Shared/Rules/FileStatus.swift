import CueEditor
import CueStore
import CueSync
import CueText
import Foundation

/// 附件文件在这台上的样子，界面各处（正文里的文件牌、输入框的附件条、对话里的文件）同一套说法：
/// 在本机写类型与大小，在传写传了几成，还没到写怎么取（记录先到、文件后到：手机上大文件、按流量计费时不自动取，点一下才取）。
nonisolated enum FileStatus {
    /// 类型：认得的写类型名（"PDF""表格"），不认得的写扩展名，没有扩展名写"文件"。
    static func kind(of name: String) -> String {
        PiPreviewKind(fileName: name)?.label ?? AttachmentKey.format(ofName: name).uppercased().nonEmpty ?? String(localized: "文件")
    }

    /// 本机那份的大小（"1.2 MB"）；读不到为 nil。
    static func size(of file: URL) -> String? {
        guard let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return bytes.formatted(.byteCount(style: .file))
    }

    /// 名字下面那一行与进度：类型 · 大小 / 上传中 40% / 下载中 40% / 点一下从 iCloud 取。图片没有名字，只写怎么取、传了几成。
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
