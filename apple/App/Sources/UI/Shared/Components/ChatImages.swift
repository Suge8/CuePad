import CueStore
import CueText
import SwiftUI

/// 图片文件随同步晚于对话到：到达之前是占位，到达的那一刻换成图。
struct ChatImages: View {
    let hashes: [String]
    var trip = BubbleTrip.arrived
    var alignment = HorizontalAlignment.trailing
    var side: CGFloat = 120
    var perRow = Self.bubbleRow
    /// 只摆前几排，没摆出的张数写在最后一格上；点它从那一张看起，全屏页里翻得到全部。
    var rows: Int?
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview

    private var singleWidth: CGFloat { side * 2.5 }
    private static var spacing: CGFloat { Spacing.tight }
    #if os(macOS)
    private static var bubbleRow: Int { 3 }
    #else
    private static var bubbleRow: Int { 2 }
    #endif

    private var group: String { "chat-" + hashes.joined(separator: ",") }

    var body: some View {
        let shown = rows.map { min(hashes.count, $0 * perRow) } ?? hashes.count
        VStack(alignment: alignment, spacing: Self.spacing) {
            ForEach(Array(stride(from: 0, to: shown, by: perRow)), id: \.self) { start in
                HStack(spacing: Self.spacing) {
                    ForEach(start..<min(start + perRow, shown), id: \.self) { index in
                        ChatImage(
                            hash: hashes[index], side: side, fitWidth: hashes.count == 1 ? singleWidth : nil,
                            more: index == shown - 1 ? hashes.count - shown : 0,
                            zoom: PreviewZoomKey(group: group, preview: PreviewItem.id(of: hashes[index]))
                        ) { open(hashes[index]) }
                    }
                }
                .transition(.opacity)
            }
        }
        .opacity(trip.opacity)
    }

    private func open(_ hash: String) {
        workspace.openAttachment(DraftFile(key: hash, name: ""), among: hashes.map { DraftFile(key: $0, name: "") }, group: group, with: openPreview)
    }
}

private struct ChatImage: View {
    let hash: String
    let side: CGFloat
    let fitWidth: CGFloat?
    let more: Int
    let zoom: PreviewZoomKey
    let open: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
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
                        Text(verbatim: AttachmentLooks.awayLine(hash, services))
                            .font(Typography.caption).monospacedDigit().foregroundStyle(palette.ink3)
                            .multilineTextAlignment(.center).padding(Spacing.tight)
                    } else if more > 0 {
                        Text(verbatim: "+\(more)").font(Typography.body.weight(.semibold)).monospacedDigit().foregroundStyle(palette.onMedia)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.mediaScrim, in: .rect(cornerRadius: Radius.block))
                            .transition(.opacity)
                    }
                }
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityLabel(more > 0 ? Text("图片，另有 \(more) 张") : Text("图片"))
        .accessibilityHint(place.isAway ? "从 iCloud 取来" : "查看大图")
        .observingArrival(of: hash, in: services, into: $place)
    }
}

struct ChatFiles: View {
    let files: [DraftFile]
    var trip = BubbleTrip.arrived

    private static var maxWidth: CGFloat { 300 }

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.tight) {
            ForEach(files) { file in
                FileChip(key: file.key, name: file.name, among: files, group: "chat-files-" + files.map(\.key).joined(separator: ","))
                    .frame(maxWidth: Self.maxWidth)
            }
        }
        .opacity(trip.opacity)
    }
}

extension PreviewItem {
    /// 名字的扩展名与键的不一致时（键按内容认的、名字没写）接上键的：全屏页按它认类型、找本机那份。
    init?(attachment file: DraftFile) {
        guard let parts = AttachmentKey.parts(file.key) else { return nil }
        let name = AttachmentKey.make(hash: parts.hash, name: file.name) == file.key ? file.name : file.name + "." + parts.format
        self.init(
            id: Self.id(of: file.key), sessionID: "", hash: parts.hash, name: file.name.isEmpty ? "image.\(parts.format)" : name,
            title: file.name.isEmpty ? String(localized: "图片") : file.name, byteCount: 0)
    }

    /// 缩略图与全屏页按它对上。
    static func id(of key: String) -> UUID {
        let hex = Array(key.prefix(32))
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
        return UUID(uuidString: groups.joined(separator: "-")) ?? UUID()
    }
}
