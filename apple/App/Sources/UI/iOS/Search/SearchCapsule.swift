#if os(iOS)
import SwiftUI
import UIKit

/// 搜索入口（窄屏项目页页顶那一排中间、iPad 侧栏顶上）：长相同搜索框（`SearchCapsule`），点它把搜索页推在当前页上，那里的搜索框接着拿到键盘（同 ⌘K）。
/// 搜索页开着时它是选中的那一格（签名色写"搜索"），不再写同一句提示：同一屏只有一个搜索框。窄到放不下整句时只写"搜索"，不截成半句。
struct SearchEntry: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let searching = workspace.top == .search
        Button(action: workspace.openSearch) {
            HStack(spacing: 6) {
                Image(.search).imageScale(.medium).foregroundStyle(searching ? palette.signature : palette.ink3)
                Group {
                    if searching {
                        Text("搜索").fontWeight(.semibold).foregroundStyle(palette.signature)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            Text(SearchScreen.prompt)
                            Text("搜索")
                        }
                        .foregroundStyle(palette.ink3)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .headerPiece(interactive: true)
        }
        .buttonStyle(PressStyle(.wide))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("搜索")
        .accessibilityAddTraits([.isButton, .isSearchField])
    }
}

/// 搜索页的搜索框：页顶那一排中间的一块写字玻璃（`headerPiece`），有字时右端是系统的清除钮。
/// `focusRequests` 每变一次（进入搜索页、再按 ⌘K）聚焦一次。
struct SearchCapsule: View {
    @Binding var query: String
    let focusRequests: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            // 导航栏里的项会把符号放大一档：定在常规档，与搜索入口、进展页搜索钮里的放大镜一样大
            Image(.search).imageScale(.medium).foregroundStyle(palette.ink3).accessibilityHidden(true)
            BarTextField(text: $query, focusRequests: focusRequests, prompt: SearchScreen.prompt)
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(maxWidth: .infinity)
        .headerPiece()
    }
}

/// 搜索框里写字的那一格，UIKit 的文本框。不用 SwiftUI 的 `TextField`：它在导航栏那一项里时 `FocusState` 两头都断（iOS 26 起，27 仍是）——
/// 设了不聚焦、点进去聚焦了也读不到，进搜索页键盘不起。焦点只有 UIKit 的第一响应者一份：聚焦请求直接让它拿。
/// 只报上屏的字。清除用系统的清除钮：自画的叉清空时输入法还攥着组合到一半的拼音，接着打的字续在那半截后面。
private struct BarTextField: UIViewRepresentable {
    @Binding var text: String
    let focusRequests: Int
    let prompt: String
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .search
        field.clearButtonMode = .always
        field.accessibilityLabel = "搜索"
        field.accessibilityTraits.insert(.searchField)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // 上屏的字一出来就报回了 `text`，没在组字时两边不同只能是外面写进来的（调试时预填的搜索词）
        if field.markedTextRange == nil, field.text != text { field.text = text }
        field.textColor = UIColor(palette.ink)
        field.attributedPlaceholder = NSAttributedString(string: prompt, attributes: [.foregroundColor: UIColor(palette.ink3)])
        if coordinator.focusRequests != focusRequests {
            coordinator.focusRequests = focusRequests
            field.focusWhenShown()
        }
    }

    final class Field: UITextField {
        private var focusPending = false

        /// 推入转场开始时这一项还没进窗口，拿不到键盘：先记着，进了窗口再拿。
        func focusWhenShown() {
            focusPending = true
            settle()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            settle()
        }

        private func settle() {
            guard focusPending, window != nil else { return }
            focusPending = false
            becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: BarTextField
        /// 已经照办的那次聚焦请求；nil 是还没照办过：搜索框一出来就要键盘。
        var focusRequests: Int?

        init(_ parent: BarTextField) { self.parent = parent }

        /// 字的每一次变化都经过这里（打字、输入法上屏、清除钮）；`editingChanged` 在选候选词上屏时不发。
        /// 拼音还没上屏时不报：搜的是上屏的字，结果不随每个字母闪"未找到"。
        func textFieldDidChangeSelection(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            if parent.text != text { parent.text = text }
        }

        /// 搜索键收起键盘：结果是边打边出的，没有另外要提交的。
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}
#endif
