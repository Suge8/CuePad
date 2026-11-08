#if DEBUG && os(iOS)
import AVFoundation
import UIKit
import WebKit

/// 一个实例只属于一轮：自己的网页、操作 continuation、计时器和事件流，绝不重绑 session。
final class DebugSplitMedia: NSObject, WKScriptMessageHandler, WKUIDelegate {
    let session = UUID()
    private let web: WKWebView
    private let scope = DebugSplitScope()
    private let events = AsyncStream<DebugSplitVoice.Frame>.makeStream()
    private var closing: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 8, height: 8), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "probe")
        web.uiDelegate = self
    }

    func receive(_ frame: DebugSplitVoice.Frame) {
        guard frame.session == session else { DebugSplitVoice.note("stale-frame-dropped kind=\(frame.kind)"); return }
        events.continuation.yield(frame)
    }

    func cancel() { scope.end(); events.continuation.finish() }

    func run(pipe: DebugSplitVoice.Pipe, cycle: Int) async throws {
        scope.spawn {
            do { try await Task.sleep(for: .seconds(100)); DebugSplitVoice.note("deadline"); self.cancel() }
            catch { }
        }
        do {
            try await prepare()
            try await exchange(pipe: pipe, cycle: cycle)
            await close()
        } catch {
            await close()
            throw error
        }
    }

    private func prepare() async throws {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw DebugSplitVoice.ProbeError.invalid
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        web.alpha = 0.01
        window.addSubview(web)
        if DebugScene.defaults.bool(forKey: "CuePadSplitMic") {
            let granted: Bool = try await scope.wait { finish in
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in finish(.success(granted)) }
                }
            }
            DebugSplitVoice.note("microphone-permission granted=\(granted)")
            guard granted else { throw DebugSplitVoice.ProbeError.invalid }
        }
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://voice.cuepad.invalid/"))
    }

    private func exchange(pipe: DebugSplitVoice.Pipe, cycle: Int) async throws {
        var observing = false
        for await event in events.stream {
            switch event.kind {
            case "ready":
                DebugSplitVoice.note("page-ready")
                let file: Any = try DebugScene.defaults.string(forKey: "CuePadSplitInput")
                    .map { try Data(contentsOf: URL(filePath: $0)).base64EncodedString() } ?? NSNull()
                guard let sdp = try await js("return await start(microphone, session, file)", arguments: [
                    "microphone": DebugScene.defaults.bool(forKey: "CuePadSplitMic"), "session": session.uuidString, "file": file,
                ]) else { throw DebugSplitVoice.ProbeError.invalid }
                try await send(.init(kind: "offer", session: session, sdp: sdp), pipe: pipe)
            case "answer":
                guard let sdp = event.sdp else { throw DebugSplitVoice.ProbeError.invalid }
                _ = try await js("await media.answer(sdp); return 'accepted'", arguments: ["sdp": sdp])
            case "connected": try await send(.init(kind: "connected", session: session), pipe: pipe)
            case "context":
                guard !observing else { continue }
                observing = true
                _ = try await js("return media.play()")
                scope.spawn {
                    do {
                        try await Task.sleep(for: .seconds(15))
                        self.events.continuation.yield(.init(kind: "observe", session: self.session))
                    } catch { }
                }
            case "observe":
                DebugSplitVoice.note("media-stats \(try await js("return JSON.stringify(await media.snapshot())") ?? "null")")
                if let pcm = try await js("return media.dump()"), let data = Data(base64Encoded: pcm),
                   let path = DebugScene.defaults.string(forKey: "CuePadSplitLog") {
                    try data.write(to: URL(filePath: path + ".\(cycle).pcm"))
                }
                // 正常挂断与异常退出使用同一个显式关闭操作；ack 仍由上层通道接收。
                _ = try await js("return await shut()")
                try await send(.init(kind: "hangup", session: session), pipe: pipe)
            case "closed": return
            case "error": throw DebugSplitVoice.ProbeError.invalid
            default: break
            }
        }
        throw DebugSplitVoice.ProbeError.ended
    }

    private func send(_ frame: DebugSplitVoice.Frame, pipe: DebugSplitVoice.Pipe) async throws {
        let _: Void = try await scope.wait { finish in
            scope.spawn {
                do { try await pipe.send(frame); finish(.success(())) }
                catch { finish(.failure(error)) }
            }
        }
    }

    private func js(_ body: String, arguments: [String: Any] = [:], in owner: DebugSplitScope? = nil) async throws -> String? {
        try await (owner ?? scope).wait { finish in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                finish(result.map { $0 as? String })
            }
        }
    }

    func close() async {
        if let closing { await closing.value; return }
        cancel()
        let cleanup = Task {
            let cleanupScope = DebugSplitScope()
            cleanupScope.spawn {
                do { try await Task.sleep(for: .seconds(2)); cleanupScope.end() }
                catch { }
            }
            do {
                let result = try await js("return await shut()", in: cleanupScope)
                DebugSplitVoice.note("explicit-shutdown \(result ?? "null")")
            } catch { DebugSplitVoice.note("explicit-shutdown-unconfirmed") }
            cleanupScope.end()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
            web.stopLoading(); web.loadHTMLString("", baseURL: nil); web.removeFromSuperview()
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { DebugSplitVoice.note("audio-deactivate-failed") }
        }
        closing = cleanup
        await cleanup.value
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !scope.ended, let body = message.body as? [String: String], let kind = body["kind"] else { return }
        let id = kind == "ready" ? session : body["session"].flatMap(UUID.init(uuidString:))
        guard let id else { return }
        receive(.init(kind: kind, session: id, detail: body["detail"]))
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(!scope.ended && type == .microphone ? .grant : .deny)
    }
}
#endif
