import CueEditor
import CueStore
import CueText
import SwiftUI

/// 正文里刚点的那个附件在哪：全屏页从这里放大、关上缩回，走缩略图同一套（`previewSource`）。
/// 编辑器是平台文本视图，附件牌子不是 SwiftUI 视图：点的那一下由宿主记下框（编辑器外层视图坐标，左上为原点），
/// `AttachmentSpotLayer` 在那里放一块看不见的视图当来源。
@Observable final class AttachmentSpot {
    static let group = "note"

    private(set) var key: String?
    private(set) var frame = CGRect.zero
    /// 第几次点：同一个附件再点一次也换一块新的来源
    private(set) var tap = 0
    @ObservationIgnored private var pending: (() -> Void)?

    /// 等那块来源上了屏（`AttachmentSpotLayer`）再打开，放大时才找得到它。
    func open(_ file: DraftFile, at frame: CGRect, in workspace: Workspace, with opener: PreviewOpener?) {
        key = file.key
        self.frame = frame
        tap += 1
        pending = { workspace.openAttachment(file, group: Self.group, with: opener) }
    }

    fileprivate func sourceAppeared() {
        pending?()
        pending = nil
    }
}

struct AttachmentSpotLayer: View {
    let spot: AttachmentSpot
    @Environment(AppServices.self) private var services

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let key = spot.key {
                // 画出来但看不见，不用 `Color.clear`：clear 不上屏，系统的 zoom 转场找不到它，就从屏幕中间放大（模拟器录屏实测）
                Rectangle()
                    .frame(width: spot.frame.width, height: spot.frame.height)
                    .opacity(0.001)
                    .previewSource(PreviewZoomKey(group: AttachmentSpot.group, preview: PiPreview.id(of: key)), cornerRadius: Radius.chip) { [files = services.store.files] in
                        await AttachmentLooks.picture(key, in: files)
                    }
                    // 用留白摆位置（不用 offset）：来源的框按排版算，偏移不算
                    .padding(.leading, spot.frame.minX).padding(.top, spot.frame.minY)
                    .id(spot.tap)
                    .onAppear { spot.sourceAppeared() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .readerHidden(true)
    }
}

extension AttachmentLooks {
    /// 出不了画面为 nil（不飞，只淡入）。
    @concurrent static func picture(_ key: String, in files: AttachmentFiles) async -> CGImage? {
        guard let file = files.fileURL(for: key) else { return nil }
        if AttachmentKey.isImage(key) { return Thumbnails.image(at: file, maxPixel: flightPixels) }
        return await Thumbnails.system(at: file, fitting: CGSize(width: flightPixels, height: flightPixels), scale: 2, icons: false)
    }

    /// 盖得住全屏页落地那一块，不解原图。
    nonisolated private static let flightPixels = 1200
}
