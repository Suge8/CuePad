#if DEBUG && os(iOS)
import AVFoundation
import Network
import UIKit
import WebKit

/// 独立模拟器进程拥有 WebRTC 媒体；Mac 不持有音轨。合成静音输入只验证传输，不证明真人听说。
final class DebugSplitMedia: NSObject, WKScriptMessageHandler, WKUIDelegate {
    private let web: WKWebView
    private let events = AsyncStream<DebugSplitVoice.Frame>.makeStream()
    private var session = UUID()
    private var ready = false

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

    static func run() async throws {
        let probe = DebugSplitMedia()
        try await probe.runCalls()
    }

    private func runCalls() async throws {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw DebugSplitVoice.ProbeError.invalid
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        DebugSplitVoice.note("media-pid=\(getpid()) audioCategory=\(audio.category.rawValue) permission=\(AVAudioApplication.shared.recordPermission.rawValue)")
        DebugSplitVoice.note("route-input=\(audio.currentRoute.inputs.map { $0.portType.rawValue }) output=\(audio.currentRoute.outputs.map { $0.portType.rawValue })")
        web.alpha = 0.01
        window.addSubview(web)
        let pipe = DebugSplitVoice.Pipe(NWConnection(host: "127.0.0.1", port: DebugSplitVoice.port, using: .tcp))
        pipe.start()
        let reader = Task {
            do { for try await frame in pipe.frames.stream { events.continuation.yield(frame) } }
            catch { DebugSplitVoice.note("signal-read-failed") }
            events.continuation.finish()
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(100))
            DebugSplitVoice.note("deadline")
            events.continuation.finish()
            pipe.close()
        }
        defer {
            reader.cancel(); deadline.cancel(); pipe.close()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
            web.loadHTMLString("", baseURL: nil); web.removeFromSuperview()
            do { try audio.setActive(false, options: .notifyOthersOnDeactivation) }
            catch { DebugSplitVoice.note("audio-deactivate-failed") }
        }
        let microphone = DebugScene.defaults.bool(forKey: "CuePadSplitMic")
        if microphone {
            let granted = await AVAudioApplication.requestRecordPermission()
            DebugSplitVoice.note("microphone-permission granted=\(granted)")
            guard granted else { throw DebugSplitVoice.ProbeError.invalid }
        }
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://voice.cuepad.invalid/"))
        var completed = 0
        var observation: Task<Void, Never>?
        defer { observation?.cancel() }
        for await event in events.stream {
            guard event.session == session else {
                DebugSplitVoice.note("stale-frame-dropped kind=\(event.kind)"); continue
            }
            switch event.kind {
            case "ready":
                guard !ready else { throw DebugSplitVoice.ProbeError.invalid }
                ready = true
                DebugSplitVoice.note("page-ready firstFrame=true")
                try await offer(pipe, microphone: microphone)
            case "answer":
                guard let sdp = event.sdp, sdp.hasPrefix("v=0") else { throw DebugSplitVoice.ProbeError.invalid }
                _ = try await js("await pc.setRemoteDescription({type:'answer',sdp}); return 'accepted'", arguments: ["sdp": sdp])
                DebugSplitVoice.note("answer-accepted bytes=\(sdp.utf8.count)")
            case "connected":
                DebugSplitVoice.note("media-connected session=\(session)")
                try await pipe.send(.init(kind: "connected", session: session))
            case "context":
                DebugSplitVoice.note("control-response session=\(session)")
                guard observation == nil else { continue }
                _ = try await js("return play()")
                let id = session
                observation = Task {
                    do { try await Task.sleep(for: .seconds(15)); events.continuation.yield(.init(kind: "observe", session: id)) }
                    catch { }
                }
            case "observe":
                let result = try await js("return JSON.stringify(await snapshot())")
                DebugSplitVoice.note("media-stats \(result ?? "null")")
                let pcm = try await js("return dump()")
                if let pcm, let data = Data(base64Encoded: pcm), let path = DebugScene.defaults.string(forKey: "CuePadSplitLog") {
                    try data.write(to: URL(filePath: path + ".\(completed).pcm"))
                    DebugSplitVoice.note("recorded pcmBytes=\(data.count) format=s16le rate=24000 channels=1")
                }
                let closed = try await js("return await shut()")
                DebugSplitVoice.note("media-closed \(closed ?? "null")")
                try await pipe.send(.init(kind: "hangup", session: session))
            case "closed":
                completed += 1
                DebugSplitVoice.note("hangup-ack cycle=\(completed)")
                if completed == 2 { return }
                observation = nil
                session = UUID()
                try await offer(pipe, microphone: microphone)
            case "error": throw DebugSplitVoice.ProbeError.invalid
            default: DebugSplitVoice.note("media-event kind=\(event.kind) detail=\(event.detail ?? "")")
            }
        }
        throw DebugSplitVoice.ProbeError.ended
    }

    private func offer(_ pipe: DebugSplitVoice.Pipe, microphone: Bool) async throws {
        let file: Any = try DebugScene.defaults.string(forKey: "CuePadSplitInput")
            .map { try Data(contentsOf: URL(filePath: $0)).base64EncodedString() } ?? NSNull()
        guard let sdp = try await js("return await start(microphone, session, file)", arguments: ["microphone": microphone, "session": session.uuidString, "file": file]) else {
            throw DebugSplitVoice.ProbeError.invalid
        }
        DebugSplitVoice.note("offer-created bytes=\(sdp.utf8.count) microphone=\(microphone)")
        try await pipe.send(.init(kind: "offer", session: session, sdp: sdp))
    }

    private func js(_ script: String, arguments: [String: Any] = [:]) async throws -> String? {
        try await web.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page) as? String
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String], let kind = body["kind"] else { return }
        guard let eventSession = kind == "ready" ? session : body["session"].flatMap(UUID.init(uuidString:)) else { return }
        events.continuation.yield(.init(kind: kind, session: eventSession, detail: body["detail"]))
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        DebugSplitVoice.note("webkit-permission microphone=\(type == .microphone)")
        decisionHandler(type == .microphone ? .grant : .deny)
    }
}
#endif
