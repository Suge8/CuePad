import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 分割线附件：独占一行、作为整体选中与删除的一条线。
/// 与图片附件同一条绘制路径（占位图 + `image(for:…)`）：不用 NSTextAttachmentViewProvider，TextKit 不保证布局后加载视图，
/// 视图还会吞点击、遮住选区高亮；线条由当前主题现画，主题变了随重排刷新。
final class CueDividerAttachment: NSTextAttachment {
    weak var core: EditorCore?

    init() {
        super.init(data: nil, ofType: nil)
        image = CueImageRendering.stub
    }

    required init?(coder: NSCoder) { nil }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let core = core
        let height = MainActor.assumeIsolated { core?.style.dividerHeight ?? 0 }
        return CGRect(x: 0, y: -height / 4, width: max(proposedLineFragment.width, 1), height: height)
    }

    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> CueImage? {
        let core = core
        return MainActor.assumeIsolated { core.map { CueImageRendering.divider(size: bounds.size, color: $0.resolved($0.style.dividerColor)) } }
    }
}
