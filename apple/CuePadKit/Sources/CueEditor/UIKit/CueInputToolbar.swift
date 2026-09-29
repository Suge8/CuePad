#if canImport(UIKit)
import UIKit

/// 键盘上方的工具栏：分块、插入图片、变量取值。后两者只发回调，由外部决定弹什么。
@MainActor
final class CueInputToolbar: UIToolbar {
    init(textView: CueTextView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        func item(_ label: String, symbol: String, action: @escaping (CueTextView) -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak textView] _ in
                if let textView { action(textView) }
            })
            item.accessibilityLabel = label
            return item
        }
        items = [
            item("分块", symbol: "rectangle.split.1x2") { $0.insertSplit() },
            .flexibleSpace(),
            item("插入图片", symbol: "photo") { $0.onInsertImageRequest?() },
            item("变量取值", symbol: "curlybraces") { $0.onVariablesRequest?() },
        ]
        sizeToFit()
    }

    required init?(coder: NSCoder) { nil }
}
#endif
