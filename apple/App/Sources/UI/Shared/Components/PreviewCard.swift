import CueStore
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// 对话里 Agent 发到手机上看的一个文件：缩略图（图片、PDF）或类型图标、标题、"类型 · 大小"，点开全屏预览（`previewPresenter`）。
/// 文件还在从 iCloud 下载时写明，下载好自动可点。
struct PreviewCard: View {
    let preview: PiPreview
    let open: (PiPreview) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    /// 文件随同步到本机的那一刻就绪（附件表变化时重读）
    @State private var arrived: Bool?
    @State private var thumbnail: CGImage?

    private var file: URL? { arrived == false ? nil : services.store.files.fileURL(for: preview.hash) }

    private static let side: CGFloat = 60

    var body: some View {
        Button { open(preview) } label: {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                    Text(file == nil ? "正在从 iCloud 下载…" : Self.caption(preview)).font(Typography.caption).foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 14)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(file == nil)
        .accessibilityLabel("预览：\(preview.title)")
        .observing(services.store, [.attachments], id: preview.hash, into: $arrived) { [files = services.store.files, hash = preview.hash] _ in
            files.fileURL(for: hash) != nil
        }
        .task(id: file) { await loadThumbnail() }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.fill)
            if let thumbnail {
                Image(decorative: thumbnail, scale: scale).resizable().scaledToFill()
            } else {
                Image(systemName: Self.symbol(preview.kind)).font(.title2).foregroundStyle(palette.ink3)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 图片按像素降采样；PDF、文本交给系统生成缩略图；网页与生成不了的用类型图标。
    private func loadThumbnail() async {
        guard let file, preview.kind != .web else { return }
        let pixels = Self.side * scale
        if preview.kind == .image {
            thumbnail = await Task.detached {
                CGImageSourceCreateWithURL(file as CFURL, nil).flatMap {
                    CGImageSourceCreateThumbnailAtIndex($0, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                    ] as CFDictionary)
                }
            }.value
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: PreviewFile.url(for: preview, original: file) ?? file, size: CGSize(width: Self.side, height: Self.side), scale: scale, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    static func symbol(_ kind: PiPreviewKind?) -> String {
        switch kind {
        case .web: "safari"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .markdown: "text.document"
        case .text, nil: "doc.plaintext"
        }
    }

    static func caption(_ preview: PiPreview) -> String {
        let label = switch preview.kind {
        case .web: "网页"
        case .image: "图片"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .text, nil: "文本"
        }
        return "\(label) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.byteCount), countStyle: .file))"
    }
}
