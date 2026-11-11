import CueEditor
import CueStore
import SwiftUI

struct FileChip: View {
    let key: String
    let name: String
    var height: CGFloat = 56
    /// 空的是只有它自己。
    var among: [DraftFile] = []
    var group = "file"
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var place = AttachmentPlace.unchecked
    @State private var thumbnail: CGImage?

    private var file: URL? { place.file(key, in: services.store.files) }
    private var thumbSide: CGFloat { height - 16 }

    var body: some View {
        let status = FileStatus.line(name: name, file: file, transfer: services.fileTransfers[key])
        Button(action: tap) {
            HStack(spacing: Spacing.item) {
                picture
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(verbatim: name).font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: status.detail).font(Typography.caption).monospacedDigit().foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.item)
            .frame(height: height)
            .background(palette.fill, in: .rect(cornerRadius: Radius.block))
            .overlay(alignment: .bottom) {
                if let progress = status.progress {
                    Capsule().fill(palette.hair)
                        .overlay { Capsule().fill(palette.ink2).scaleEffect(x: progress, anchor: .leading) }
                        .frame(height: 3)
                        .padding(.leading, thumbSide + Spacing.block).padding(.trailing, Spacing.group).padding(.bottom, Spacing.tight)
                        .animation(Motion.fade, value: progress)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityLabel(Dotted(name, status.detail).spoken)
        .accessibilityHint(file == nil ? "从 iCloud 取来" : "打开")
        .observingArrival(of: key, in: services, into: $place)
        .task(id: file) {
            guard let file else { return thumbnail = nil }
            thumbnail = await Thumbnails.chip(at: file, side: thumbSide, scale: scale)
        }
    }

    private var picture: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: scale).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: Radius.chip))
            } else {
                Image(Icon.file(named: name)).font(Glyph.large).foregroundStyle(palette.ink3)
            }
        }
        .frame(width: thumbSide, height: thumbSide)
        .previewSource(PreviewZoomKey(group: group, preview: PreviewItem.id(of: key)), cornerRadius: Radius.chip) { [files = services.store.files, key] in
            await AttachmentLooks.picture(key, in: files)
        }
    }

    private func tap() {
        workspace.openAttachment(DraftFile(key: key, name: name), among: among, group: group, with: openPreview)
    }
}

struct ImageTile: View {
    let key: String
    var side: CGFloat = 64
    var among: [DraftFile] = []
    var group = "file"
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview
    @Environment(\.displayScale) private var scale
    @State private var place = AttachmentPlace.unchecked

    var body: some View {
        Button {
            workspace.openAttachment(DraftFile(key: key, name: ""), among: among, group: group, with: openPreview)
        } label: {
            Thumbnail(hash: key, height: side, cornerRadius: Radius.block).frame(width: side).id(place.isAway)
                .previewSource(PreviewZoomKey(group: group, preview: PreviewItem.id(of: key)), cornerRadius: Radius.block) { [files = services.store.files, key, side, scale] in
                    await Thumbnail.picture(key, height: side, scale: scale, in: files)
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("图片")
        .observingArrival(of: key, in: services, into: $place)
    }
}
