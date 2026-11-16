import CueEditor
import CueStore
import CueText
import SwiftUI

struct Thumbnail: View {
    let hash: String
    var height: CGFloat
    var cornerRadius: CGFloat = Radius.block
    var fitWidth: CGFloat?
    /// 铺在卡顶、由卡自己裁圆角时是直角、不描边。
    var framed = true
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var place = AttachmentPlace.unchecked

    private struct Request: Equatable {
        let hash: String
        let height: CGFloat
        let scale: CGFloat
        let place: AttachmentPlace
    }

    var body: some View {
        Rectangle()
            .fill(palette.fill)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: fitWidth == nil ? .fill : .fit)
                        // 深色下截图多是亮底，原样放在暗纸上刺眼：压暗一层
                        .overlay { palette.mediaDim }
                        // 铺满时裁掉的那截还接着指针（裁切只管画）：宽图会盖住旁边的格子，悬停亮错、点了没反应
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: fitWidth == nil ? .infinity : nil)
            .clipShape(framed ? AnyShape(.rect(cornerRadius: cornerRadius)) : AnyShape(.rect))
            .overlay { if framed { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(palette.hair) } }
            .observingArrival(of: hash, in: services, into: $place)
            .task(id: Request(hash: hash, height: height, scale: scale, place: place)) {
                guard place != .unchecked else { return }
                image = await Self.picture(hash, height: height, scale: scale, in: services.store.files)
            }
    }

    /// 全屏页飞出与占位用的也是它（你的话里带的图、点名图），同一份不另解。不在本机为 nil。
    static func picture(_ hash: String, height: CGFloat, scale: CGFloat, in files: AttachmentFiles) async -> CGImage? {
        guard let url = files.fileURL(for: hash) else { return nil }
        return await decode(url, pixels: Int(height * 3 * scale))
    }

    @concurrent private static func decode(_ url: URL, pixels: Int) async -> CGImage? { Thumbnails.image(at: url, maxPixel: pixels) }

    private var width: CGFloat? {
        guard let fitWidth else { return nil }
        guard let image, image.height > 0 else { return height }
        return min(fitWidth, height * CGFloat(image.width) / CGFloat(image.height))
    }
}
