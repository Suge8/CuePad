#if DEBUG
import CueStore
import CueText
import Foundation

extension DebugScene {
    static func seedBindings(_ store: CueStore, projects: [Project]) async throws {
        try await store.publishDirectoryBindings(host: "demo-mac")
        let directories = try await store.projectDirectories()
        let others = projects.filter { $0.name != "CuePad" }.map(\.id)
        for id in others { try await store.setDirectory(nil, for: id) }
        try await store.publishDirectoryBindings(host: "demo-air")
        for id in others { if let directory = directories[id] { try await store.setDirectory(directory, for: id) } }
    }

    /// 任务三态：圆桌"乱序"的子任务"复现乱序""改成按首次加入时间排序""部署到预发环境"开了工，正文发给了会话 piwork、atlas、deploy
    /// （子任务记着会话；复现乱序随后完成，它的会话 piwork 已结束：会话页看完成了的任务），"补 3 个重连用例"还没开始；
    /// CuePad"投送超时"的正文发给 notes；CuePad、Flow、圆桌各完成一条（先后完成）。
    static func seedTaskStates(_ store: CueStore, projects: [Project]) async throws {
        let tasks = try await store.tasks(.todo).flatMap(\.tasks)
        // 发出的正文留在任务上，任务记着会话
        func send(_ prefix: String, to session: String) async throws {
            guard let task = tasks.first(where: { $0.body.hasPrefix(prefix) }) else { return }
            _ = try await store.recordSend(task.body, to: SendTarget(kind: .piSession, name: session, ref: session), card: task.id)
        }
        try await send(String(localized: "复现乱序", table: "Demo"), to: "piwork")
        try await send(String(localized: "投送队列超时报错不发键", table: "Demo"), to: "notes")
        try await send(String(localized: "改成按首次加入时间排序", table: "Demo"), to: "atlas")
        try await send(String(localized: "部署到预发环境", table: "Demo"), to: "deploy")
        if let reproduce = tasks.first(where: { $0.body.hasPrefix(String(localized: "复现乱序", table: "Demo")) }) { try await store.setStatus(reproduce.id, .done) }
        // notes 这一轮几分钟前做完，会话歇下
        await Task.wait(for: .milliseconds(5))
        _ = try await PiStateRecorder(store: store, hostID: "demo-mac").update(
            sessionID: "notes", state: .settled, title: "notes", directory: "notes", projectID: projects.first { $0.name == "Career" }?.id,
            times: PiTimes(stateSince: .now.addingTimeInterval(-6 * 60), busySince: nil), modelState: demoModels, commands: demoCommands)
        let cuepad = tasks.filter { $0.projectID == projects.first { $0.name == "CuePad" }?.id && !$0.body.hasPrefix(String(localized: "投送队列超时报错不发键", table: "Demo")) }
        if let started = cuepad.first { try await store.setStatus(started.id, .inProgress) }
        // Flow 只有一条在推进的任务、没有 Agent：项目的"此刻"是这条任务
        if let canvas = tasks.first(where: { $0.body.hasPrefix(String(localized: "画布缩放锚点跟随指针", table: "Demo")) }) { try await store.setStatus(canvas.id, .inProgress) }
        if cuepad.count > 1 { try await store.setStatus(cuepad[1].id, .done) }
        // 再完成两个别的项目的，最近完成那组跨项目、按完成时间排
        for name in ["Flow", String(localized: "圆桌", table: "Demo")] {
            guard let task = tasks.last(where: { $0.projectID == projects.first { $0.name == name }?.id }) else { continue }
            await Task.wait(for: .milliseconds(5))
            try await store.setStatus(task.id, .done)
        }
    }

    /// notes 会话最后一轮：你让 Agent 发页面、截图、报告来看，Agent 先截了手机宽度的图，再在命令行里 `cuepad show` 了两次——
    /// 页面一张卡，截图与评审结论一起一张卡（对话里按创建时间排在你的话与回答之间）；工具清单只有截图那条，发卡片的命令不列（`PiToolLog`）。
    static func seedPreviews(_ store: CueStore, now: Date) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appending(path: "login-v2.html")
        let shot = directory.appending(path: "login-mobile.png")
        let report = directory.appending(path: "review.md")
        try Self.loginPage.write(to: page, atomically: true, encoding: .utf8)
        try Self.review.write(to: report, atomically: true, encoding: .utf8)
        try Self.screenshotPNG()?.write(to: shot)
        var created: [Date] = []
        for batch in [[(page, String(localized: "登录页 v2：可点的完整页面", table: "Demo"))], [(shot, String(localized: "手机截图：登录钮在键盘上方", table: "Demo")), (report, String(localized: "评审结论：还有三处要改", table: "Demo"))]] {
            created.append(try await store.addPreviews(batch.map { (url: $0.0, title: $0.1) }, sessionID: "notes")[0].preview.createdAt)
        }
        // 对话围着预览的创建时间排：你的话在先，回答在后
        guard let first = created.first, let last = created.last else { return }
        let screenshot = try screenshotMarkup(store), pdf = try demoPDF(store)
        let messages = [
            PiChatMessage(
                sessionID: "notes", entryID: "u9", seq: 8, role: .user, text: String(localized: "把登录页的新样子、手机上的截图和评审结论发给我看看，样子参考这张", table: "Demo") + (screenshot.map { "\n" + $0 } ?? "")
                    + "\n" + pdf.markup,
                at: first.addingTimeInterval(-50)),
            PiChatMessage(
                sessionID: "notes", entryID: "p9", seq: 9, role: .pi, text: String(localized: "发给你了：完整页面可以直接点按钮试交互，截图是 iPhone 宽度下的样子，评审结论里有两处要你定。", table: "Demo"),
                at: last.addingTimeInterval(2), tools: .init(steps: 1, items: [.init(kind: .command, target: "npx playwright screenshot --device 'iPhone 15' login-v2.html login-mobile.png")]), roundStartedAt: first.addingTimeInterval(-50)),
        ]
        try await store.writePiTranscript(PiTranscript(
            sessionID: "notes", messages: messages,
            recap: PiRecap(lastPrompt: messages[0].text, lastReply: messages.last?.text)))
    }

    /// 演示用的工具活动：一周会议记录那一轮读了资料、改了笔记、跑了脚本。
}
#endif
