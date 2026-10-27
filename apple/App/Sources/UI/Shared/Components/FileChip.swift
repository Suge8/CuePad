import CueEditor
import CueStore
import QuickLookThumbnailing
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 一个文件（不是图片）的牌子，同正文里的文件牌（`CueFileAttachment`）：左边缩略图（系统快速查看的，文件不在本机或出不来时是类型记号），
/// 右边文件名与一行说明（`FileStatus`：类型与大小、传了几成、怎么取），在传时底下一条进度。
/// 点它：在本机就打开（`open`，不给是系统的快速查看），还没到就去 iCloud 取，到了自己换上。输入框的附件条、带上的卡片全文、你的话里的文件都是它。
struct FileChip: View {
    let key: String
    let name: String
    var height: CGFloat = 56
    /// 在本机时点它做什么；nil 时快速查看。
    var open: ((URL) -> Void)?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var arrived: Bool?
    @State private var thumbnail: CGImage?

    private var file: URL? { arrived == false ? nil : services.store.files.fileURL(for: key) }
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
        .observingArrival(of: key, in: services, into: $arrived)
        .task(id: file) {
            guard let file else { return thumbnail = nil }
            thumbnail = await Self.thumbnail(file, side: thumbSide, scale: scale)
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
        guard let file else { return workspace.fetchFile(key) }
        if let open { open(file) } else { FilePreview.open(file, title: name) }
    }

    @concurrent private static func thumbnail(_ file: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: side, height: side), scale: scale, representationTypes: .all)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// 附件条里的一张图：方块缩略图，点它快速查看；还没到这台时点它去取。
struct ImageTile: View {
    let key: String
    var side: CGFloat = 64
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @State private var arrived: Bool?

    var body: some View {
        Button {
            guard arrived != false, let file = services.store.files.fileURL(for: key) else { return workspace.fetchFile(key) }
            FilePreview.open(file, title: String(localized: "图片"))
        } label: {
            Thumbnail(hash: key, height: side, radius: 12).frame(width: side).id(arrived ?? true)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("图片")
        .observingArrival(of: key, in: services, into: $arrived)
    }
}

/// 系统的快速查看看本机那份附件（文件名是键，标题另给）：手机上从最前面的窗口弹出，Mac 是快速查看面板。
@MainActor
enum FilePreview {
    static func open(_ file: URL, title: String) {
        #if os(iOS)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        if let window { QuickLook.show(file, title: title, from: window) }
        #else
        QuickLook.show(file, title: title)
        #endif
    }
}
