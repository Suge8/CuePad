import SwiftUI

/// "出错"的样子，全 App 只此一份：胭脂（`Palette.failure`）圆叹号。会话出错（`PiShown`）、操作失败的提示、同步出错、
/// 启动问题、读不出资料库、崩溃报告都用它，不另画三角——同一个意思一个样子，用户只学一次。与它并列的"等你"在 `Waiting`。
enum Failure {
    static let symbol = "exclamationmark.circle.fill"
}

/// 跟着字号的出错图形：胭脂圆叹号。读屏跳过，意思由旁边的字说。
struct FailureMark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: Failure.symbol).foregroundStyle(palette.failure).accessibilityHidden(true)
    }
}
