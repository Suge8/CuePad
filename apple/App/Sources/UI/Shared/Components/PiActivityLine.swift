import SwiftUI

/// Pi 此刻在做什么的一行：前缀（项目、状态）加详情（工具命令、弹窗标题、出错原因）。Mac 与 iOS 共用，
/// 字体与截断只在这里定：命令用等宽字，整行一行、从尾部截断（命令开头的程序名最有信息量），悬停（指针设备）看全文。
struct PiActivityLine: View {
    var lead: [String?] = []
    var detail: String?
    var detailIsCode = false
    var font: Font = .footnote
    /// 悬停显示的全文（如出错原文）；默认就是这一行。
    var full: String?

    var body: some View {
        let prefix = lead.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        let separator = prefix.isEmpty || detail == nil ? "" : " · "
        let detailText = Text(verbatim: detail ?? "").font(detailIsCode ? font.monospaced() : font)
        Text("\(Text(verbatim: prefix + separator))\(detailText)")
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(full ?? prefix + separator + (detail ?? ""))
    }
}
