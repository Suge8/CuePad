import SwiftUI

/// Pi 此刻在做什么的一行（工具命令、弹窗标题、出错原因）。命令开头最有信息量，所以只保留一行、从尾部截断，
/// 悬停（指针设备）看全文。Mac 与 iOS 共用，各处不要再自己写截断方式。
struct PiActivityLine: View {
    let text: String
    var font: Font = .footnote
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? font.monospaced() : font)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }

    /// "状态 · 详情"，空的部分略去。
    static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
