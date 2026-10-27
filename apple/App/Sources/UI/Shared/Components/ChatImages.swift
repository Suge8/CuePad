import CueStore
import CueText
import SwiftUI

/// 你的话里带的图片（对话里的气泡与还没进对话的气泡共用）：缩略图排在文字气泡下面，靠右；只有一张时按原比例（同高，宽不超过 `singleWidth`，
/// 不裁），几张时一行 `perRow` 张方块；点一张在交付物同一个全屏页里看（`openPreview`，几张左右翻）。
/// 图片文件随同步晚于对话到：到达之前是占位，写着传了几成（还没开始取的写怎么取，点了就取），到达的那一刻换成图。
/// 还在路上的话整片变淡，与文字气泡一致。
struct ChatImages: View {
    let hashes: [String]
    var trip = BubbleTrip.arrived
    @Environment(Workspace.self) private var workspace
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
                            zoom: PreviewZoomKey(group: group, preview: PiPreview.id(of: hashes[index]))
                        ) { open(hashes[index]) }
                    }
                }
            }
        }
        .opacity(trip.opacity)
    }

    /// 已到本机的几张作为一组打开，从点的那张起。
    private func open(_ hash: String) {
        workspace.openAttachment(DraftFile(key: hash, name: ""), among: hashes.map { DraftFile(key: $0, name: "") }, group: group, with: openPreview)
    }
}

private struct ChatImage: View {
    let hash: String
    let side: CGFloat
    let fitWidth: CGFloat?
    let zoom: PreviewZoomKey
    let open: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    /// 文件到本机的那一刻就绪
    @State private var place = AttachmentPlace.unchecked

    var body: some View {
        Button { if place.isAway { workspace.fetchFile(hash) } else { open() } } label: {
            // 到达时换一个身份，缩略图重新读文件；一开始就在的不重读
            Thumbnail(hash: hash, height: side, cornerRadius: Radius.block, fitWidth: fitWidth).frame(width: fitWidth == nil ? side : nil).id(place.isAway)
                .previewSource(zoom, cornerRadius: Radius.block) { [files = services.store.files, hash, side, scale] in
                    await Thumbnail.picture(hash, height: side, scale: scale, in: files)
                }
                .overlay {
                    if place.isAway {
                        Text(verbatim: FileStatus.line(name: "", file: nil, transfer: services.fileTransfers[hash]).detail)
                            .font(Typography.caption).monospacedDigit().foregroundStyle(palette.ink3)
                            .multilineTextAlignment(.center).padding(6)
                    }
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("图片")
        .accessibilityHint(place.isAway ? "从 iCloud 取来" : "查看大图")
        .observingArrival(of: hash, in: services, into: $place)
    }

}

/// 你的话里带的文件（会话记录里的"附件：名（路径）"认回来的引用也是）：气泡下面一行一个文件牌（`FileChip`），靠右；
/// 点一个在交付物同一个全屏页里看（`openPreview`，几个左右翻），还没到这台的点了去取。还在路上的话整片变淡，与文字气泡一致。
struct ChatFiles: View {
    let files: [DraftFile]
    var trip = BubbleTrip.arrived

    private static var maxWidth: CGFloat { 300 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(files) { file in
                FileChip(key: file.key, name: file.name, among: files, group: "chat-files-" + files.map(\.key).joined(separator: ","))
                    .frame(maxWidth: Self.maxWidth)
            }
        }
        .opacity(trip.opacity)
    }
}

extension PiPreview {
    /// 你的话里带的一个附件在全屏页里按交付物认一份：同一份同一个身份（`id(of:)`）；图片没有名字，标题写"图片"。
    /// 名字的扩展名与键的不一致时（键按内容认的、名字没写）接上键的：全屏页按它认类型、找本机那份。
    init?(attachment file: DraftFile) {
        guard let parts = AttachmentKey.parts(file.key) else { return nil }
        let name = AttachmentKey.make(hash: parts.hash, name: file.name) == file.key ? file.name : file.name + "." + parts.format
        self.init(
            id: Self.id(of: file.key), sessionID: "", hash: parts.hash, name: file.name.isEmpty ? "image.\(parts.format)" : name,
            title: file.name.isEmpty ? String(localized: "图片") : file.name, byteCount: 0)
    }

    /// 同一份附件同一个身份（哈希的前 128 位）：缩略图与全屏页按它对上。
    static func id(of key: String) -> UUID {
        let hex = Array(key.prefix(32))
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
        return UUID(uuidString: groups.joined(separator: "-")) ?? UUID()
    }
}
