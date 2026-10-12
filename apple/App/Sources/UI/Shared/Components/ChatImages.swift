import CueStore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 你的话里带的图片（对话里的气泡与还没进对话的气泡共用）：缩略图排在文字气泡下面，靠右，一行 `perRow` 张；点一张用系统的快速查看看大图
/// （缩放、分享都有）。图片文件随同步到手机晚于对话：到达之前是占位且点不开，到达的那一刻换成图（附件表变化时重读）。
/// 还在路上的话整片变淡，与文字气泡一致。
struct ChatImages: View {
    let hashes: [String]
    var trip = BubbleTrip.arrived
    @State private var opened: URL?

    private static var side: CGFloat { 120 }
    private static var spacing: CGFloat { 6 }
    #if os(macOS)
    private static var perRow: Int { 3 }
    #else
    private static var perRow: Int { 2 }
    #endif

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.spacing) {
            ForEach(Array(stride(from: 0, to: hashes.count, by: Self.perRow)), id: \.self) { start in
                HStack(spacing: Self.spacing) {
                    ForEach(start..<min(start + Self.perRow, hashes.count), id: \.self) { index in
                        ChatImage(hash: hashes[index], side: Self.side) { opened = $0 }
                    }
                }
            }
        }
        .quickLookPreview($opened)
        .opacity(trip == .inTransit ? 0.6 : 1)
    }
}

private struct ChatImage: View {
    let hash: String
    let side: CGFloat
    let open: (URL) -> Void
    @Environment(AppServices.self) private var services
    /// 文件随同步到本机的那一刻就绪
    @State private var arrived: Bool?

    var body: some View {
        Button(action: show) {
            // 到达时换一个身份，缩略图重新读文件；一开始就在的不重读
            Thumbnail(hash: hash, height: side, radius: 12).frame(width: side).id(arrived ?? true)
        }
        .buttonStyle(PressStyle())
        .disabled(arrived == false)
        .accessibilityLabel("图片")
        .accessibilityHint("查看大图")
        .observing(services.store, id: hash, into: $arrived) { [files = services.store.files, hash] store in
            try store.hasAttachment(hash) && files.fileURL(for: hash) != nil
        }
    }

    private func show() {
        guard let original = services.store.files.fileURL(for: hash) else { return }
        let type = CGImageSourceCreateWithURL(original as CFURL, nil).flatMap(CGImageSourceGetType)
        let ext = type.flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "png"
        if let url = PreviewFile.url(hash: hash, name: "图片.\(ext)", original: original) { open(url) }
    }
}
