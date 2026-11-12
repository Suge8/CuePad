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

    static func seedTaskStates(_ store: CueStore, projects: [Project]) async throws {
        let tasks = try await store.tasks(.todo).flatMap(\.tasks)
        func send(_ prefix: String, to session: String) async throws {
            guard let task = tasks.first(where: { $0.body.hasPrefix(prefix) }) else { return }
            _ = try await store.recordSend(task.body, to: SendTarget(kind: .piSession, name: session, ref: session), card: task.id)
        }
        try await send(String(localized: "复现乱序", table: "Demo"), to: "piwork")
        try await send(String(localized: "投送队列超时报错不发键", table: "Demo"), to: "notes")
        try await send(String(localized: "改成按首次加入时间排序", table: "Demo"), to: "atlas")
        try await send(String(localized: "部署到预发环境", table: "Demo"), to: "deploy")
        if let reproduce = tasks.first(where: { $0.body.hasPrefix(String(localized: "复现乱序", table: "Demo")) }) { try await store.setStatus(reproduce.id, .done) }
        await Task.wait(for: .milliseconds(5))
        _ = try await demoRecorder(store).update(
            sessionID: "notes", state: .settled, title: "notes", directory: "notes", projectID: projects.first { $0.name == "Career" }?.id,
            times: SessionTimes(stateSince: .now.addingTimeInterval(-6 * 60), busySince: nil), modelState: demoModels, commands: demoCommands)
        let cuepad = tasks.filter { $0.projectID == projects.first { $0.name == "CuePad" }?.id && !$0.body.hasPrefix(String(localized: "投送队列超时报错不发键", table: "Demo")) }
        if let started = cuepad.first { try await store.setStatus(started.id, .inProgress) }
        // Flow 只有一条在推进的任务、没有 Agent：项目的"此刻"是这条任务
        if let canvas = tasks.first(where: { $0.body.hasPrefix(String(localized: "画布缩放锚点跟随指针", table: "Demo")) }) { try await store.setStatus(canvas.id, .inProgress) }
        if cuepad.count > 1 { try await store.setStatus(cuepad[1].id, .done) }
        for name in ["Flow", String(localized: "圆桌", table: "Demo")] {
            guard let task = tasks.last(where: { $0.projectID == projects.first { $0.name == name }?.id }) else { continue }
            await Task.wait(for: .milliseconds(5))
            try await store.setStatus(task.id, .done)
        }
    }

    static func seedPreviews(_ store: CueStore, now: Date) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appending(path: "login-v2.html")
        let shot = directory.appending(path: "login-mobile.png")
        let report = directory.appending(path: "review.md")
        let change = directory.appending(path: "login.diff")
        try Self.loginPage.write(to: page, atomically: true, encoding: .utf8)
        try Self.loginDiff.write(to: change, atomically: true, encoding: .utf8)
        try Self.review.write(to: report, atomically: true, encoding: .utf8)
        try Self.screenshotPNG()?.write(to: shot)
        var created: [Date] = []
        for batch in [[(page, String(localized: "登录页 v2：可点的完整页面", table: "Demo"))], [(shot, String(localized: "手机截图：登录钮在键盘上方", table: "Demo")), (report, String(localized: "评审结论：还有三处要改", table: "Demo"))],
                      [(change, String(localized: "改动：错误提示改成一行字", table: "Demo"))]] {
            created.append(try await store.addPreviews(batch.map { (url: $0.0, title: $0.1) }, sessionID: "notes")[0].preview.createdAt)
        }
        guard let first = created.first, let last = created.last else { return }
        let screenshot = try screenshotMarkup(store), pdf = try demoPDF(store)
        let looked = try Self.screenshotPNG().map { try store.files.store($0) }
        let messages = [
            ChatMessage(
                sessionID: "notes", entryID: "u9", seq: 8, role: .user, text: String(localized: "把登录页的新样子、手机上的截图和评审结论发给我看看，样子参考这张", table: "Demo") + (screenshot.map { "\n" + $0 } ?? "")
                    + "\n" + pdf.markup,
                at: first.addingTimeInterval(-50)),
            ChatMessage(
                sessionID: "notes", entryID: "p9", seq: 9, role: .pi, text: notesPreviewReply,
                at: last.addingTimeInterval(2), tools: .init(steps: 2, items: [
                    .init(kind: .command, target: "npx playwright screenshot --device 'iPhone 15' login-v2.html login-mobile.png"),
                    .init(kind: .read, target: "login-mobile.png", images: looked.map { [$0] }),
                // 缓存一小时前就冷了：回复框上方提醒这一句要重读多少
                ], cache: .init(context: 164_000, warmUntil: .now.addingTimeInterval(-3_600))), roundStartedAt: first.addingTimeInterval(-50)),
        ]
        try await store.writeTranscript(SessionTranscript(
            sessionID: "notes", messages: messages,
            recap: Recap(lastPrompt: messages[0].text, lastReply: messages.last?.text)))
    }

}
#endif
