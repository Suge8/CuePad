import CueEditor
import CueStore
import SwiftUI

/// 一个文件（不是图片）的牌子，同正文里的文件牌（`CueFileAttachment`）：左边缩略图（系统快速查看的，文件不在本机或出不来时是类型记号），
/// 右边文件名与一行说明（`FileStatus`：类型与大小、传了几成、怎么取），在传时底下一条进度。
/// 点它：在本机就在全屏页里看（同组 `among` 里已到的几份左右翻，`Workspace.openAttachment`），还没到就去 iCloud 取，到了自己换上。
/// 输入框的附件条、带上的卡片全文、你的话里的文件都是它。
struct FileChip: View {
    let key: String
    let name: String
    var height: CGFloat = 56
    /// 和它一组的几份（附件条、一句话、一张卡里的），空的是只有它自己；`group` 认这一组。
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
            HStack(spacing: 10) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: status.detail).font(Typography.caption).monospacedDigit().foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(palette.fill, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) {
                if let progress = status.progress {
                    // 传了几成：一条细线，靠左长到那一成
                    Capsule().fill(palette.hair)
                        .overlay { Capsule().fill(palette.ink2).scaleEffect(x: progress, anchor: .leading) }
                        .frame(height: 3)
                        .padding(.leading, thumbSide + 18).padding(.trailing, 12).padding(.bottom, 5)
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
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
            } else {
                Image(Icon.file(named: name)).font(.title3).foregroundStyle(palette.ink3)
            }
        }
        .frame(width: thumbSide, height: thumbSide)
    }

    private func tap() {
        workspace.openAttachment(DraftFile(key: key, name: name), among: among, group: group, with: openPreview)
    }
}

/// 附件条里的一张图：方块缩略图，点它在全屏页里看（同 `FileChip`）；还没到这台时点它去取。
struct ImageTile: View {
    let key: String
    var side: CGFloat = 64
    var among: [DraftFile] = []
    var group = "file"
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview
    @State private var place = AttachmentPlace.unchecked

    var body: some View {
        Button {
            workspace.openAttachment(DraftFile(key: key, name: ""), among: among, group: group, with: openPreview)
        } label: {
            Thumbnail(hash: key, height: side, radius: 12).frame(width: side).id(place.isAway)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("图片")
        .observingArrival(of: key, in: services, into: $place)
    }
}
