import SwiftUI

struct StarterBar: View {
    let draft: FileDraft
    @Environment(\.palette) private var palette

    var body: some View {
        LibraryFileBar {
            Text("CuePad 备了一份起步规则").font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(2)
            Spacer(minLength: Spacing.item)
            Button("填进来") { draft.fill(Self.text) }
                .buttonStyle(ControlButtonStyle(kind: .secondary, size: .compact))
        }
    }

    static var text: String {
        String(localized: """
            # 做事的标准

            - 把这个项目当成你自己的作品：分析要彻底，建议要大胆。
            - 版本与 API 用法查一手来源，不凭印象。
            - 修根因，不打表面补丁；同一根因的其他出现处一并修。
            - 用当下最轻的做法：不加用不到的抽象、中间层与配置，不为不会发生的情况写防御。
            - 同一条规则、配置、状态只留一个权威来源；这次改动造成的死代码、过时的文档与测试一并删掉。
            - 只做被要求的；看到范围外的问题，在回复末尾提一句，不顺手改。
            - 测试只写覆盖用户可见行为的，不为凑数写。
            - 验证只跑一次能覆盖这次改动的检查；没验到的写明没验。
            - 界面沿用项目已有的组件与设计语言：标题直接说内容，不加不带信息的说明句与小标签，一屏一个焦点。
            - 推送、发布、删除数据这类收不回的事，做之前先问。

            """)
    }
}
