#if os(iOS) && DEBUG
import UIKit

/// `-CuePadKeyboard system`：模拟器连着电脑键盘时也弹出系统键盘（截键盘弹出的样子用；模拟器默认当作接了硬件键盘、不弹）。
/// `-CuePadKeyboard tall`：输入框换成一块模拟的第三方键盘，先按系统键盘的高弹出，过一会儿长出一排工具栏、变得比系统键盘高
/// （第三方键盘的扩展加载完才定高，带工具栏的比系统键盘高）；点它在两种高之间切（换键盘、工具栏收放）。
/// 核对输入框一直贴在键盘上方。只换输入视图，打字不用它。
final class DebugKeyboard: UIInputView {
    private static let low: CGFloat = 260
    private static let tall: CGFloat = 340
    private static let settle: Duration = .milliseconds(600)
    private let toolbar = UIView()
    private lazy var height = heightAnchor.constraint(equalToConstant: Self.low)

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        // 高只由约束定：留着自动转换的话，初始框的高会变成一条同样必需的约束，改高不生效
        translatesAutoresizingMaskIntoConstraints = false
        height.isActive = true
        toolbar.backgroundColor = .systemTeal.withAlphaComponent(0.35)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        let label = UILabel()
        label.text = "模拟第三方键盘（工具栏）"
        label.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(label)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.tall - Self.low),
            label.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])
        toolbar.isHidden = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        // 截图等它长高后再拍
        DebugHooks.later(Self.settle) { [weak self] in self?.toggle() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var mode: String? { DebugScene.defaults.string(forKey: "CuePadKeyboard") }

    static func make() -> DebugKeyboard? {
        if mode == "system" { showSoftwareKeyboard() }
        return mode == "tall" ? DebugKeyboard() : nil
    }

    /// 输入法清掉硬件键盘布局后按没接硬件键盘弹出软键盘（私有选择子，只在 Debug 里）。
    private static func showSoftwareKeyboard() {
        let selector = NSSelectorFromString("setHardwareLayout:")
        for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) { mode.perform(selector, with: nil) }
    }

    @objc private func toggle() {
        toolbar.isHidden.toggle()
        height.constant = toolbar.isHidden ? Self.low : Self.tall
        // 键盘按新的高重排：同第三方键盘改了自己的高
        UIApplication.shared.sendAction(#selector(UIResponder.reloadInputViews), to: nil, from: nil, for: nil)
    }
}
#endif
