import CueEditor
import CueStore
import CueText
import SwiftUI

/// 正文（编辑器）里刚点的那个附件画面在哪：全屏页从这里放大出来、关上缩回这里，走缩略图同一套（`previewSource`）。
/// 编辑器是平台的文本视图，牌子不是 SwiftUI 视图：点的那一下由编辑器的宿主记下框（编辑器外层视图的坐标，左上为原点），
/// 盖在编辑器上的 `AttachmentSpotLayer` 在那里放一块看不见、不接点按的视图当来源。
@Observable final class AttachmentSpot {
    /// 正文里的附件在全屏页里属于哪一组（`Workspace.openAttachment`，放大的来源按它认）
    static let group = "note"

    private(set) var key: String?
    private(set) var frame = CGRect.zero
    /// 第几次点：同一个附件再点一次也换一块新的来源
    private(set) var tap = 0
    @ObservationIgnored private var pending: (() -> Void)?

    /// 点了正文里的一个附件：记下它的框，等那块来源上了屏（`AttachmentSpotLayer`）再打开，放大时才找得到它。
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

/// 盖在编辑器上（`AttachmentSpot` 的那一处）。
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
                    .previewSource(PreviewZoomKey(group: AttachmentSpot.group, preview: PiPreview.id(of: key)), radius: 5) { [files = services.store.files] in
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
        .accessibilityHidden(true)
    }
}

extension AttachmentLooks {
    /// 全屏页放大、缩回时飞的那张画面：图片按原图降采样，别的文件是系统缩略图（PDF 的页、视频的帧）；出不了画面为 nil（不飞，只淡入）。
    @concurrent static func picture(_ key: String, in files: AttachmentFiles) async -> CGImage? {
        guard let file = files.fileURL(for: key) else { return nil }
        if AttachmentKey.isImage(key) { return Thumbnails.image(at: file, maxPixel: flightPixels) }
        return await Thumbnails.system(at: file, fitting: CGSize(width: flightPixels, height: flightPixels), scale: 2, icons: false)
    }

    /// 飞的那张最长边：盖得住全屏页落地那一块，不解原图
    nonisolated private static let flightPixels = 1200
}
