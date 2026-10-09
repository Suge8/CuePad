import CueStore
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// 对话里 Agent 发到手机上看的一组文件（同一处连着发的收在一张纸上，一个一行，行间只靠留白）：点哪个全屏预览哪个（`previewPresenter`）。
struct PreviewGroup: View {
    let previews: [PiPreview]
    let open: (PiPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(previews) { PreviewCard(preview: $0, open: open) }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 14)
    }
}

/// 一组里的一个文件：缩略图（图片、PDF）或类型图标、标题、"类型 · 大小"。文件还在从 iCloud 下载时写明，下载好自动可点。
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

    private static let side: CGFloat = 44

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
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 10))
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
                // 深色下缩略图（多是白底的页面）压暗一点，不在暗处亮成一块白
                Image(decorative: thumbnail, scale: scale).resizable().scaledToFill()
                    .brightness(palette.dark ? -0.18 : 0)
            } else {
                Image(systemName: Self.symbol(preview.kind)).font(.title2).foregroundStyle(palette.ink3)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.hair))
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
        return "\(label) · \(size(preview.byteCount))"
    }

    /// 大小一律按 KB 起写（不出现"393 字节"与"1 KB"并排）：不到 1 KB 也写 1 KB，过 1000 KB 写 MB。
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(max(bytes, 1000)))
    }
}
