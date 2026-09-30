import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 分隔线附件：不可编辑控件，自带编号标签与复制/发送按钮（视图 `CueDividerView` 是平台差异）。
final class CueDividerAttachment: NSTextAttachment {
    weak var core: EditorCore?
    weak var view: CueDividerView?
    var label = ""

    init() { super.init(data: nil, ofType: nil) }
    required init?(coder: NSCoder) { nil }

    override func viewProvider(
        for parentView: CueView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = CueDividerViewProvider(
            textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class CueDividerViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        nonisolated(unsafe) let attachment = textAttachment as! CueDividerAttachment
        view = MainActor.assumeIsolated {
            let divider = CueDividerView(attachment: attachment)
            attachment.view = divider
            return divider
        }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        nonisolated(unsafe) let attachment = textAttachment as! CueDividerAttachment
        let height = MainActor.assumeIsolated { attachment.core?.style.dividerHeight ?? 28 }
        return CGRect(x: 0, y: -height / 4, width: max(proposedLineFragment.width, 1), height: height)
    }
}
