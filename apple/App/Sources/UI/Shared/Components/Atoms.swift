import SwiftUI

/// 读屏不念（行要读的话由行自己的标签给）。
struct Dot: View {
    var body: some View { Text("·").readerHidden(true) }
}

extension LocalizedStringResource {
    /// 收界面字的参数拿到的是已经算好或用户写的字（项目名、会话标题、Agent 说的）：原样显示，不查目录。
    static func verbatim(_ text: String) -> Self { "\(text)" }
}

extension View {
    /// 分开时 Mac 的菜单按钮按子视图拆成几颗，菜单项只挂在第一颗下，读屏落在别的那颗上打开的是空壳。标签只有一个图标时不用它，给菜单本身 `accessibilityLabel` 就够。
    func menuLabel(_ spoken: LocalizedStringResource) -> some View { accessibilityElement(children: .ignore).accessibilityLabel(spoken) }
}

extension View {
    /// 系统在它自己的线程上发这个通知：按主线程上的任务等，`action` 改的界面状态不跨线程。
    func onDayChange(_ action: @escaping () -> Void) -> some View {
        task { for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) { action() } }  // 晚订：视图出现前换的日子，出现时画的就是新的一天
    }
}

struct SectionHeader: View {
    enum Level { case page, group }

    let title: Dotted
    var level = Level.page
    var count: Int?
    var icon: Icon?
    @Environment(\.palette) private var palette

    init(_ title: Dotted, level: Level = .page, count: Int? = nil, icon: Icon? = nil) {
        self.title = title
        self.level = level
        self.count = count
        self.icon = icon
    }

    init(_ title: LocalizedStringResource, level: Level = .page, count: Int? = nil, icon: Icon? = nil) {
        self.init(Dotted(String(localized: title)), level: level, count: count, icon: icon)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
            if let icon { Image(icon).readerHidden(true) }
            Text(title)
            if let count { Text("\(count)").font(countFont).monospacedDigit().foregroundStyle(palette.ink3).counting(count) }
        }
        .font(titleFont)
        .foregroundStyle(level == .page ? palette.ink : palette.ink3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var titleFont: Font {
        level == .page ? Typography.sectionTitle : Typography.label
    }

    private var countFont: Font {
        level == .page ? Typography.sectionCount : Typography.label
    }
}
