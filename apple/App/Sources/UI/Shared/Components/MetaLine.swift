import SwiftUI

/// 一行字接行尾的元信息（时间、时长、读数）：常规字号并排，元信息按自己的宽靠右、不截，字先占满剩下的；
/// 辅助字号下元信息换到字的下一行、从行首起——并排时元信息不让，字被挤得每行只剩一两个字，或连行带卡撑出屏幕。
/// 并排时就是 `HStack(alignment:spacing:) { 字; Spacer(minLength: gap); 元信息 }`：没有元信息时字后面照样留 `spacing + gap`。
/// 两种排法是两棵树而不是一个 `AnyLayout`：`AnyLayout` 报的首行基线与 `HStack` 差零点几点，外面按基线对齐时整行字会挪一像素。
/// Mac 没有辅助字号，总是并排。
struct MetaLine<Lead: View, Meta: View>: View {
    var alignment = VerticalAlignment.firstTextBaseline
    var spacing: CGFloat = 0
    let gap: CGFloat
    @ViewBuilder let lead: Lead
    @ViewBuilder let meta: Meta
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                lead
                meta.fixedSize()
            }
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                lead
                Spacer(minLength: gap)
                meta.fixedSize()
            }
        }
    }
}
