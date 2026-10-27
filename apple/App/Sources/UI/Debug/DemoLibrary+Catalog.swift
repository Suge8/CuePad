#if DEBUG
import CueStore
import CueText
import Foundation

extension DemoLibrary {
    /// `doc`：一份 PDF 的引用，`docs`：它加一份日志（只带一个、两个文件的灵感看附件标记）。
    static func projects(image: String, doc: String, docs: String) -> [DemoProject] {
        let home = demoHome
        let pic = CueFormat.imageMarkup(key: image)
        return [
            DemoProject(name: "CuePad", icon: .sparkles, color: "#A260C4", pinned: false, directory: "\(home)Project/cuepad", intro: String(localized: "投送队列本月可上线", table: "Demo"), cards: [
                (0.2, String(localized: "修复 TextKit 编辑器\n\nTextKit 编辑器偶发失败。先稳定复现，定位根因后再改，不要加重试掩盖。", table: "Demo"), false),
                (0.6, String(localized: "设计 iCloud 同步\n\n给 iCloud 同步出三个方案，比较代价，推荐一个并说明理由。\n---\n约束：离线并发编辑保留两个版本，不静默覆盖。", table: "Demo"), false),
                (1.2, String(localized: "变量模板文档\n\n\(pic)\n更新变量模板的开发文档，删掉过时的说明。", table: "Demo"), false),
                (1.5, String(localized: "排查 Pi 桥\n\n日志里 Pi 桥报错 {{错误码}}，查清触发条件再动手。\n\(docs)", table: "Demo"), false),
                (2.0, String(localized: "重构菜单栏面板\n\n把 {{模块路径}} 里的菜单栏面板拆成独立模块，保持公开接口不变。\n\n- 唤起到可输入 < 100ms\n- 参考 [NSPanel 文档](https://developer.apple.com/documentation/appkit/nspanel)\n---\n完成后把改动摘要写进发布说明。", table: "Demo"), false),
                (3.0, String(localized: "评审：导入旧数据\n\n审查 {{分支}} 中导入旧数据相关改动，只报告会导致错误行为的问题。", table: "Demo"), false),
                (4.0, String(localized: "优化回收站性能\n\n回收站在 {{数据量}} 条时明显卡顿，先测量再优化。", table: "Demo"), false),
                (5.5, String(localized: "迁移投送队列\n\n把投送队列迁到新的存储层，旧数据一次性导入。\n\(doc)", table: "Demo"), false),
                (6.0, String(localized: "想法：TextKit 编辑器\n\n\(pic)\n编辑器的附件也许可以按视口懒加载，只挂缩略图。", table: "Demo"), false),
                (9.0, String(localized: "变量模板补测试\n\n在接缝上给变量模板补验收测试，先看到它失败，再实现。", table: "Demo"), false),
                (12.0, String(localized: "Todo\n\n- 截图换成 Swift 版\n- 续费域名\n- 更新落地页", table: "Demo"), false),
                (18.0, String(localized: "排查剪贴板回读\n\n写入后回读偶尔为空，先确认是不是竞态。", table: "Demo"), false),
                (21.0, String(localized: "评审：快捷键录制\n\n只看会导致错误行为的问题。", table: "Demo"), false),
                (26.0, String(localized: "想法：发送记录\n\n一键重发时带上当时的变量取值。", table: "Demo"), false),
                (33.0, String(localized: "重构设置页\n\n设置项的描述写打开后会发生什么。", table: "Demo"), false),
                (38.0, String(localized: "排查 socket 残留\n\n强杀后 socket 没删，检查 kqueue 退出通知。\n\(doc)", table: "Demo"), false),
                (45.0, String(localized: "设计通知\n\nPi 完成与等你确认时推送，点通知跳到会话。", table: "Demo"), false),
                (52.0, String(localized: "整理发布清单\n\n签名、公证、Sparkle 更新源。\n\(docs)", table: "Demo"), false),
                (60.0, String(localized: "修复拖入图片\n\n拖入 HEIC 时缩略图空白。", table: "Demo"), false),
                (75.0, String(localized: "想法：卡片墙\n\n只在打开项目或跨天时重排，同一次打开里墙不自己挪动。", table: "Demo"), false),
                (84.0, String(localized: "评审：搜索筛选\n\n分页前先筛选，总数不受分页影响。", table: "Demo"), false),
                (110.0, String(localized: "旧方案：轮询会话状态\n\n每两秒查一次，耗电。", table: "Demo"), false),
                (130.0, String(localized: "调研 CKSyncEngine\n\n记录级同步、资产上传与冲突处理。", table: "Demo"), false),
                (170.0, String(localized: "原型：三个视觉方向\n\n桌面、看板、流。", table: "Demo"), false),
                (200.0, String(localized: "常用提示：代码评审\n\n只报告会导致错误行为的问题，按严重程度排序。", table: "Demo"), true),
            ]),
            DemoProject(name: String(localized: "圆桌", table: "Demo"), icon: .chat, color: "#D9774B", pinned: true, directory: "\(home)Project/atlas", intro: String(localized: "多 Agent 调度本月可上线", table: "Demo"), cards: [
                (1.0, String(localized: "产品决策\n\n先列出现状和约束，再给出下一步。", table: "Demo"), false),
                (2.5, String(localized: "评审：计费额度\n\n审查 {{分支}} 中计费额度相关改动。", table: "Demo"), true),
                (40.0, String(localized: "主持人提示词\n\n\(pic)\n提示词写好，一键投送。", table: "Demo"), false),
            ]),
            DemoProject(name: "Flow", icon: .layers, color: "#3AA088", pinned: true, directory: nil, cards: [
                (1.0, String(localized: "撤销栈合并连续拖拽\n\n连续拖拽只记一步撤销。", table: "Demo"), false),
                (15.0, String(localized: "画布缩放\n\n双指缩放锚点跟随指针。", table: "Demo"), false),
            ]),
            DemoProject(name: String(localized: "闲鱼", table: "Demo"), icon: .cart, color: "#3F8FB8", pinned: false, directory: nil, intro: String(localized: "二手相机这周挂出去", table: "Demo"), cards: [
                (3.0, String(localized: "定价补测试\n\n在接缝上给定价补验收测试。", table: "Demo"), false),
            ]),
            DemoProject(name: String(localized: "个人网站", table: "Demo"), icon: .globe, color: "#C9A227", pinned: false, directory: "\(home)Project/homepage", cards: [
                (8.0, String(localized: "首页改版\n\n给首页改版出三个方案，比较代价。", table: "Demo"), false),
            ]),
            DemoProject(name: "Career", icon: .briefcase, color: "#5E9E5A", pinned: false, directory: nil, cards: [
                (20.0, String(localized: "求职信\n\n按岗位描述改写第一段。", table: "Demo"), false),
            ]),
            DemoProject(name: String(localized: "读书", table: "Demo"), icon: .book, color: "#D0607D", pinned: false, directory: nil, intro: String(localized: "每周读完一章", table: "Demo"), cards: [
                (30.0, String(localized: "《设计心理学》第二章\n\n示能与意符的区别。", table: "Demo"), false),
            ]),
            DemoProject(name: String(localized: "旅行", table: "Demo"), icon: .globe, color: "#3F8FB8", pinned: false, directory: nil, cards: [
                (12.0, String(localized: "京都行程\n\n第二天去岚山，避开周末。", table: "Demo"), false),
            ]),
            DemoProject(name: String(localized: "装修", table: "Demo"), icon: .hammer, color: "#8A8A84", pinned: false, directory: nil, cards: [
                (6.0, String(localized: "比价\n\n三家报价，水电分开算。", table: "Demo"), false),
            ]),
        ]
    }

    static let tasks: [DemoTask] = [
        ("CuePad", String(localized: "投送队列超时报错不发键", table: "Demo"), false),
        ("CuePad", String(localized: "导入旧数据时保留回收站", table: "Demo"), false),
        ("CuePad", String(localized: "菜单栏面板 ⌘↩ 直接发出", table: "Demo"), false),
        ("CuePad", String(localized: "小组件显示进行中的任务", table: "Demo"), false),
        ("CuePad", String(localized: "分享扩展支持多张图片", table: "Demo"), false),
        ("CuePad", String(localized: "设置页加快捷键冲突提示", table: "Demo"), false),
        ("CuePad", String(localized: "首次启动引导绑定文件夹", table: "Demo"), true),
        ("CuePad", String(localized: "深色模式下纸色偏灰", table: "Demo"), true),
        (String(localized: "圆桌", table: "Demo"), String(localized: "发言轮次乱序", table: "Demo"), false),
        (String(localized: "圆桌", table: "Demo"), String(localized: "登录回调改走统一网关", table: "Demo"), false),
        (String(localized: "圆桌", table: "Demo"), String(localized: "房间链接过期后给出提示", table: "Demo"), false),
        (String(localized: "圆桌", table: "Demo"), String(localized: "主持人可以静音全部", table: "Demo"), false),
        (String(localized: "圆桌", table: "Demo"), String(localized: "清理旧的计费脚本", table: "Demo"), true),
        ("Flow", String(localized: "画布缩放锚点跟随指针", table: "Demo"), false),
        ("Flow", String(localized: "撤销栈合并连续拖拽", table: "Demo"), false),
        ("Flow", String(localized: "导出 PNG 时保留透明背景", table: "Demo"), false),
        ("Flow", String(localized: "节点吸附到网格", table: "Demo"), false),
        ("Flow", String(localized: "多选后统一改颜色", table: "Demo"), false),
        (nil, String(localized: "README 截图换成 Swift 版", table: "Demo"), false),
        (nil, String(localized: "续费域名", table: "Demo"), false),
    ]

    typealias DemoTask = (project: String?, text: String, done: Bool)
}
#endif
