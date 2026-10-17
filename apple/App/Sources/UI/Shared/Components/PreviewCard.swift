import AVFoundation
import CueStore
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// 对话里 Agent 一次发到手机上看的几个文件：一张纸，一个文件一行，行间只靠留白；点哪个全屏预览哪个（`previewPresenter`）。
/// 几个共用一个标题（`--title`）时标题写在纸的最上面，各行写文件名；否则各行写自己的标题。
struct PreviewGroup: View {
    let previews: [PiPreview]
    let open: (PiPreview) -> Void
    @Environment(\.palette) private var palette

    /// 几个文件共用的标题；一个文件或各有各的标题时为 nil。
    private var heading: String? { Self.heading(previews) }

    static func heading(_ batch: [PiPreview]) -> String? {
        guard batch.count > 1, let title = batch.first?.title, batch.allSatisfy({ $0.title == title }) else { return nil }
        return title
    }

    /// 一个文件在卡片行上与全屏页顶上的写法：共用标题时写文件名，否则写自己的标题。
    static func label(of preview: PiPreview, in batch: [PiPreview]) -> String { heading(batch) == nil ? preview.title : preview.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let heading {
                Text(heading).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(2)
                    .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(previews) { PreviewCard(preview: $0, label: Self.label(of: $0, in: previews), open: open) }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 14)
    }
}

/// 卡里的一个文件：缩略图（画面就是内容的几类，见 `load`）或类型图标、文字、"类型 · 时长 · 大小"。文件还在从 iCloud 下载时写明，下载好自动可点。
struct PreviewCard: View {
    let preview: PiPreview
    let label: String
    let open: (PiPreview) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    /// 文件随同步到本机的那一刻就绪（附件表变化时重读）
    @State private var arrived: Bool?
    @State private var thumbnail: CGImage?
    /// 音频、视频的时长
    @State private var duration: String?

    private var file: URL? { arrived == false ? nil : services.store.files.fileURL(for: preview.hash) }

    private static let side: CGFloat = 44

    var body: some View {
        Button { open(preview) } label: {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                    Text(file == nil ? "正在从 iCloud 下载…" : Dotted(preview.kind?.label, duration, Self.size(preview.byteCount)))
                        .font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
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
        .accessibilityLabel("预览：\(label)")
        .observing(services.store, id: preview.hash, into: $arrived, immediately: false) { [files = services.store.files, hash = preview.hash] store in
            try store.hasAttachment(hash) && files.fileURL(for: hash) != nil
        }
        .task(id: file) { await load(file) }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.fill)
            if let thumbnail {
                // 深色下缩略图（多是白底的页面）压暗一点，不在暗处亮成一块白
                Image(decorative: thumbnail, scale: scale).resizable().scaledToFill()
                    .overlay { palette.mediaDim }
            } else {
                Image(systemName: Self.symbol(preview.kind)).font(.title2).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            if preview.kind == .video, thumbnail != nil {
                Image(systemName: "play.fill").font(.footnote).foregroundStyle(palette.onMedia).shadow(radius: 2).accessibilityHidden(true)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.hair))
    }

    /// 画面就是内容的有缩略图：图片按像素降采样，视频、PDF、演示文稿、3D 交给系统生成；其余用类型图标：网页渲染缩略图时会去联网，
    /// 音频只有通用图标，文稿、表格、文本在这么小的格子里是一张几乎空白的纸。音频、视频再读出时长。
    private func load(_ stored: URL?) async {
        // 系统认类型靠扩展名：附件目录里的文件以哈希为名，用按文件名放的那一份
        guard let stored, let file = PreviewFile.url(hash: preview.hash, name: preview.systemFileName, original: stored) else { return }
        if preview.kind == .audio || preview.kind == .video {
            duration = (try? await AVURLAsset(url: file).load(.duration)).flatMap { Self.clock($0.seconds) }
        }
        if preview.kind == .image {
            let pixels = Self.side * scale
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
        guard [.video, .pdf, .presentation, .model].contains(preview.kind) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: Self.side, height: Self.side), scale: scale, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    static func symbol(_ kind: PiPreviewKind?) -> String {
        switch kind {
        case .web: "safari"
        case .markdown: "text.document"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .model: "cube"
        case .text, nil: "doc.plaintext"
        }
    }

    /// 时长写成"0:03""12:40""1:02:05"。
    static func clock(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded()).formatted(.time(pattern: pattern))
    }

    /// 大小一律按 KB 起写（不出现"393 字节"与"1 KB"并排）：不到 1 KB 也写 1 KB，过 1000 KB 写 MB。
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(max(bytes, 1000)))
    }
}
