import CueStore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 你的话里带的图片（对话里的气泡与还没进对话的气泡共用）：缩略图排在文字气泡下面，靠右；只有一张时按原比例（同高，宽不超过 `singleWidth`，
/// 不裁），几张时一行 `perRow` 张方块；点一张在交付物同一个全屏页里看（`openPreview`，几张左右翻）。
/// 图片文件随同步到手机晚于对话：到达之前是占位且点不开，到达的那一刻换成图（附件表变化时重读）。
/// 还在路上的话整片变淡，与文字气泡一致。
struct ChatImages: View {
    let hashes: [String]
    var trip = BubbleTrip.arrived
    @Environment(AppServices.self) private var services
    @Environment(\.openPreview) private var openPreview

    private static var side: CGFloat { 120 }
    private static var singleWidth: CGFloat { side * 2.5 }
    private static var spacing: CGFloat { 6 }
    #if os(macOS)
    private static var perRow: Int { 3 }
    #else
    private static var perRow: Int { 2 }
    #endif

    /// 放大与缩回按"这几张 + 哪一张"认缩略图
    private var group: String { "chat-" + hashes.joined(separator: ",") }

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.spacing) {
            ForEach(Array(stride(from: 0, to: hashes.count, by: Self.perRow)), id: \.self) { start in
                HStack(spacing: Self.spacing) {
                    ForEach(start..<min(start + Self.perRow, hashes.count), id: \.self) { index in
                        ChatImage(
                            hash: hashes[index], side: Self.side, fitWidth: hashes.count == 1 ? Self.singleWidth : nil,
                            zoom: PreviewZoomKey(group: group, preview: Self.id(of: hashes[index]))
                        ) { open(hashes[index]) }
                        .disabled(openPreview == nil)
                    }
                }
            }
        }
        .opacity(trip.opacity)
    }

    /// 已到本机的几张作为一组打开，从点的那张起。
    private func open(_ hash: String) {
        let batch = hashes.compactMap(preview)
        guard let opened = batch.first(where: { $0.hash == hash }) else { return }
        openPreview?(PreviewOpening(preview: opened, batch: batch, group: group))
    }

    /// 全屏页按交付物认一份：文件名的扩展名按图片的真实格式取（系统按扩展名认类型），标题是"图片"。没到本机的为 nil。
    private func preview(_ hash: String) -> PiPreview? {
        guard let original = services.store.files.fileURL(for: hash) else { return nil }
        let type = CGImageSourceCreateWithURL(original as CFURL, nil).flatMap(CGImageSourceGetType)
        let ext = type.flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "png"
        return PiPreview(id: Self.id(of: hash), sessionID: "", hash: hash, name: "image.\(ext)", title: String(localized: "图片"), byteCount: 0)
    }

    /// 同一张图同一个身份（哈希的前 128 位）：缩略图与全屏页按它对上。
    private static func id(of hash: String) -> UUID {
        let hex = Array(hash.prefix(32))
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
        return UUID(uuidString: groups.joined(separator: "-")) ?? UUID()
    }
}

private struct ChatImage: View {
    let hash: String
    let side: CGFloat
    let fitWidth: CGFloat?
    let zoom: PreviewZoomKey
    let open: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.displayScale) private var scale
    /// 文件随同步到本机的那一刻就绪
    @State private var arrived: Bool?

    var body: some View {
        Button(action: open) {
            // 到达时换一个身份，缩略图重新读文件；一开始就在的不重读
            Thumbnail(hash: hash, height: side, radius: Self.radius, fitWidth: fitWidth).frame(width: fitWidth == nil ? side : nil).id(arrived ?? true)
                .previewSource(zoom, radius: Self.radius) { [files = services.store.files, hash, side, scale] in
                    await Thumbnail.picture(hash, height: side, scale: scale, in: files)
                }
        }
        .buttonStyle(PressStyle())
        .disabled(arrived == false)
        .accessibilityLabel("图片")
        .accessibilityHint("查看大图")
        .observingArrival(of: hash, in: services.store, into: $arrived)
    }

    private static let radius: CGFloat = 12
}
