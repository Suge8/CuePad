#if os(macOS)
import AppKit
import CueStore
import WebKit

extension LivePreview {

    /// 一个动作：等用户停手、做、等页面安定，回执附上跳转与这一下之后的新报错。
    func agentAct(_ act: Act, mark: (tint: String, ink: String)) async throws -> LiveChannel.Reply {
        try await agentReady()
        try requireLocal()
        let waited = try await waitForUser()
        // 等的这几秒里页面可能自己跳到了外网
        try requireLocal()
        let start = record.end, from = web.url
        agent.acting = true
        defer { agent.acting = false }
        var text: String
        switch act {
        case .click(let ref): text = try await click(ref, mark: mark)
        case .fill(let ref, let value): text = try await fill(ref, value, mark: mark)
        case .press(let key, let ref): text = try await press(key, ref, mark: mark)
        case .upload(let ref, let files): text = try await upload(ref, files, mark: mark)
        case .eval(let code): text = try await evaluate(code)
        }
        if waited > .milliseconds(100) { text += "（先等用户停手 \(Self.seconds(waited))）" }
        await settle()
        if let url = web.url, url != from {
            text += "\n页面到了 \(url.absoluteString)"
            if !LiveAddress.isLocal(url) { text += "\n这是外网地址：之后不替你操作，snapshot、screenshot、console 还能用" }
        }
        let fresh = record.unseen(from: start)
        if !fresh.isEmpty {
            let shown = fresh.prefix(5)
            text += "\n这一下之后控制台新的报错与警告 \(fresh.count) 条：\n" + shown.map { record.entry($0).line }.joined(separator: "\n")
            if fresh.count > shown.count { text += "\n……另有 \(fresh.count - shown.count) 条：cuepad live console" }
            record.markSeen(shown)
        }
        return .done(text, LiveChannel.Info(url: web.url?.absoluteString))
    }

    func click(_ ref: String, mark: (tint: String, ink: String)) async throws -> String {
        let target = try target(ref)
        var how = ""
        let described: String
        if web.window != nil {
            let armed = try await call("return cue.arm({ n })", ["n": target.n], in: target.document)
            described = armed["did"] as? String ?? ""
            let point: CGPoint
            do {
                point = try await mainPoint(of: target, CGPoint(x: armed["x"] as? Double ?? 0, y: armed["y"] as? Double ?? 0))
            } catch {
                _ = try? await call("return await cue.disarm()", in: target.document)
                throw error
            }
            nativeClick(at: point)
            do {
                let landed = try await call("return await cue.disarm()", in: target.document, stopsOnAsk: true, stopsOnLeave: true)
                if landed["seen"] as? Bool != true {
                    // 原生事件没进这份文档：什么也没点到，退回合成的
                    _ = try await call("return cue.click({ n })", ["n": target.n], in: target.document, stopsOnAsk: true)
                    how = "（真实鼠标事件没进到页面里，退回了脚本合成的点击）"
                } else if landed["got"] as? Bool != true {
                    how = "（按下去了，但页面没在它身上收到点击，落在 <\(landed["where"] as? String ?? "?")> 上：页面可能在按下时换掉了它，snapshot 看一眼）"
                }
            } catch is AskPending {
            } catch is PageLeft {}
        } else {
            do {
                let done = try await call("return cue.click({ n })", ["n": target.n], in: target.document, stopsOnAsk: true)
                described = done["did"] as? String ?? ""
            } catch is AskPending {
                described = ref
            }
            how = "（用户没开着预览，用的是脚本合成的点击）"
        }
        await flash(target, String(localized: "Agent 点"), mark)
        return "点了 \(described)\(how)"
    }

    func fill(_ ref: String, _ value: String, mark: (tint: String, ink: String)) async throws -> String {
        let target = try target(ref)
        let done = try await call("return cue.fill({ n, text })", ["n": target.n, "text": value], in: target.document)
        await flash(target, done["chose"] as? Bool == true ? String(localized: "Agent 选") : String(localized: "Agent 填"), mark)
        return done["did"] as? String ?? ""
    }

    func press(_ key: String, _ ref: String?, mark: (tint: String, ink: String)) async throws -> String {
        guard key.count == 1 || Self.keys.contains(key) else {
            throw LiveRefusal("不认识的键「\(key)」：可以是 \(Self.keys.joined(separator: "、")) 或单个字符")
        }
        if let ref {
            let target = try target(ref)
            let done = try await call("return cue.press({ n, key })", ["n": target.n, "key": key], in: target.document)
            await flash(target, String(localized: "Agent 按 \(key)"), mark)
            return done["did"] as? String ?? ""
        }
        // 没给引用：按在此刻有焦点的那份文档里（焦点在框里时是那个框）
        guard let main = record.main, let document = record.documents[main] else { throw LiveRefusal("页面还没载出来") }
        let done = try await call("return cue.press({ n: null, key })", ["key": key], in: document)
        return done["did"] as? String ?? ""
    }

    static let keys = ["Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Space"]

    func upload(_ ref: String, _ uploads: [LiveChannel.Upload], mark: (tint: String, ink: String)) async throws -> String {
        let target = try target(ref)
        let files = try keep(uploads)
        agent.upload = files
        defer { agent.upload = nil }
        // 脚本里点文件框照样弹得出选文件（WebKit 把原生调的脚本当作用户手势）：要文件的那一下由 UI 代理交出 `agent.upload`
        let done = try await call("return cue.chooseFile({ n })", ["n": target.n], in: target.document)
        if files.count > 1, done["multiple"] as? Bool != true { throw LiveRefusal("这个文件框只收一个文件，给了 \(files.count) 个") }
        let deadline = ContinuousClock.now + .seconds(3)
        while agent.upload != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard agent.upload == nil else { throw LiveRefusal("点了文件框，页面没要文件") }
        await flash(target, String(localized: "Agent 交文件"), mark)
        return "\(done["did"] as? String ?? "") 交了 \(files.count) 个文件：\(files.map(\.lastPathComponent).joined(separator: "、"))"
    }

    /// 命令行交来的内容写进这个预览自己的临时目录，页面拿到的是这里的文件：页面读文件（提交、FileReader）在交过之后，留到预览释放。
    private func keep(_ uploads: [LiveChannel.Upload]) throws -> [URL] {
        let folder = uploadFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 每个文件各占一层：不同目录里的同名文件不互相盖掉
        return try uploads.enumerated().map { index, upload in
            let name = URL(filePath: upload.name).lastPathComponent
            guard !name.isEmpty, name != "..", name != "." else { throw LiveRefusal("文件名不对：\(upload.name)") }
            let place = folder.appending(path: "\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let url = place.appending(path: name)
            try upload.data.write(to: url)
            return url
        }
    }

    /// 没写 return 的当一个表达式算（`document.title`），写了的是函数体；当表达式语法不通时再当函数体（语法错在执行之前报，前一次什么也没跑），
    /// 那一次的语法错页面会当成未捕获的错报一条（"Script error."），不算这一下的新报错。
    private func evaluate(_ code: String) async throws -> String {
        let wrap = { (body: String) in "const value = await (async () => {\n\(body)\n})();\nif (value === undefined) return 'undefined';\ntry { return JSON.stringify(value) ?? String(value); } catch { return String(value); }" }
        let run = { (body: String) in try await self.bounded(.seconds(10)) { try await self.web.callAsyncJavaScript(wrap(body), arguments: [:], in: nil, contentWorld: .page) } }
        let value: Any?
        do {
            if code.contains(/\breturn\b/) {
                value = try await run(code)
            } else {
                let before = record.end
                do {
                    value = try await run("return (\n\(code)\n);")
                } catch let error where Self.message(error).hasPrefix("SyntaxError") {
                    record.markSeen(record.unseen(from: before))
                    value = try await run(code)
                }
            }
        } catch let error as LiveRefusal {
            throw error
        } catch {
            throw LiveRefusal("页面里抛了错：\(Self.message(error))")
        }
        let text = value as? String ?? "\(value ?? "null")"
        guard text.utf8.count > Self.evalLimit else { return text }
        let cut = String(decoding: text.utf8.prefix(Self.evalLimit), as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\u{FFFD}"))
        return cut + "\n…（截到 8 KB，共 \(text.utf8.count / 1024) KB）"
    }

    private func flash(_ target: Aim, _ word: String, _ mark: (tint: String, ink: String)) async {
        // 弹着对话框时页面的脚本停着，画不上
        guard asks.isEmpty else { return }
        _ = try? await call("return cue.markRef({ n, word, tint, ink })", ["n": target.n, "word": word, "tint": mark.tint, "ink": mark.ink], in: target.document, within: .seconds(1))
    }

    /// 合成的 NSEvent 直接交给网页视图，不经窗口派发：页面里 `isTrusted` 为真，不动用户的指针，窗口不用在前、不抢焦点。
    private func nativeClick(at point: CGPoint) {
        guard let window = web.window else { return }
        let zoom = web.pageZoom * web.magnification
        let inView = CGPoint(x: point.x * zoom, y: web.isFlipped ? point.y * zoom : web.bounds.height - point.y * zoom)
        let location = web.convert(inView, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
        }
    }

    /// 框里的一点换到主框的视口里：一层层加上 iframe 内容区的位置，每一层都核对那一点上最上面的就是这个 iframe（被挡住的框不点）。
    func mainPoint(of target: Aim, _ point: CGPoint) async throws -> CGPoint {
        var point = point, token = target.token
        while let host = agent.page?.hosts[token] {
            guard let parent = record.documents[host.parent] else { throw LiveRefusal("\(target.ref) 所在的框已不在：重新 cuepad live snapshot") }
            let box = try await call("return cue.frameBox({ n })", ["n": host.frame], in: parent)
            point.x += box["x"] as? Double ?? 0
            point.y += box["y"] as? Double ?? 0
            let hits = try await call("return { hit: cue.hitsFrame({ n, x, y }) }", ["n": host.frame, "x": point.x, "y": point.y], in: parent)
            guard hits["hit"] as? Bool == true else { throw LiveRefusal("\(target.ref) 所在的框被挡住了，点不到：先关掉挡着的") }
            token = host.parent
        }
        guard token == record.main else { throw LiveRefusal("\(target.ref) 所在的框接不上主页面：重新 cuepad live snapshot") }
        return point
    }

    /// 动作之后等页面安定：先给事件处理与渲染一拍，再等载入与请求回来（最多 5 秒；弹了对话框就不等），最后再给一拍渲染。
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
        let deadline = ContinuousClock.now + .seconds(5)
        while (web.isLoading || record.pending > 0) && asks.isEmpty && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(30))
    }
}
#endif
