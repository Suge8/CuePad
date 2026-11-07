#if os(macOS)
import AppKit
import WebKit

/// 实时语音的媒体那一头：系统 WebKit 里的一个 WebRTC 连接（`RTCPeerConnection`），声音进出都在这里，信令与控制在 `VoiceCall`。
/// 选 WebKit 不另引 libwebrtc：订阅的语音只给 WebRTC（WebSocket 要 API Key），WebKit 自带完整 ICE，UDP 不通时自己用 TCP 连服务器的 443 候选，
/// 回声消除、降噪、Opus 都是系统的；代价是一个 WebContent 进程（通话时才有）。
/// WebKit 只在挂进窗口的网页里让 AudioContext 跑起来：放进一扇看不见的屏外小窗。
/// 声音来源二选一：麦克风（`getUserMedia`，要麦克风权限），或一段音频文件（`play` 时播进连接，无人值守的验收用）；
/// 给了 `recording` 时把对方的声音录成 24 kHz 单声道 WAV（`close` 时写出），这时不外放。
@MainActor
final class VoicePeer: NSObject {
    enum Source { case microphone, file(URL) }
    enum Event: Equatable {
        case connected, failed
        /// 文件播完了
        case inputEnded
        /// 对方的声音响起、停下（峰值过阈值）
        case output(loud: Bool)
    }

    var onEvent: (Event) -> Void = { _ in }
    private let source: Source
    private let recording: URL?
    private let web: WKWebView
    private let window: NSWindow

    init(source: Source, recording: URL?) {
        self.source = source
        self.recording = recording
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 8, height: 8), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "peer")
        web.uiDelegate = self
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
    }

    /// 起连接、收集完本机候选（不逐个送出：服务器一次收下整份），返回要交给服务器的 SDP。
    func offer() async throws -> String {
        try await load()
        let file: String? = if case .file(let url) = source { try Data(contentsOf: url).base64EncodedString() } else { nil }
        let sdp = try await web.callAsyncJavaScript("return await start(file, record)", arguments: ["file": file ?? NSNull(), "record": recording != nil], contentWorld: .page)
        guard let sdp = sdp as? String else { throw VoicePeerError.noOffer }
        return sdp
    }

    func accept(answer: String) async throws {
        _ = try await web.callAsyncJavaScript("return await answer(sdp)", arguments: ["sdp": answer], contentWorld: .page)
    }

    /// 文件来源：从现在起播进连接，播完报 `inputEnded`。
    func play() async throws {
        _ = try await web.callAsyncJavaScript("return play()", contentWorld: .page)
    }

    /// 断开；有录音就写出。
    func close() async {
        if let recording, let pcm = try? await web.callAsyncJavaScript("return dump()", contentWorld: .page) as? String, let data = Data(base64Encoded: pcm) {
            try? Self.wav(data).write(to: recording)
        }
        _ = try? await web.callAsyncJavaScript("close()", contentWorld: .page)
        window.close()
    }

    private func load() async throws {
        // https 的源才算安全上下文（麦克风、WebRTC 都要）；页面不联网，源只是个名字
        let ready = AsyncStream<Void>.makeStream()
        loaded = ready.continuation
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://voice.cuepad.invalid/"))
        for await _ in ready.stream { break }
    }

    private var loaded: AsyncStream<Void>.Continuation?

    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready": loaded?.yield(); loaded?.finish()
        case "state":
            switch body["state"] as? String {
            case "connected": onEvent(.connected)
            case "failed": onEvent(.failed)
            default: break
            }
        case "inputEnded": onEvent(.inputEnded)
        case "output": onEvent(.output(loud: body["loud"] as? Bool == true))
        default: break
        }
    }

    private static func wav(_ pcm: Data) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let rate: UInt32 = 24000
        var header = Data("RIFF".utf8)
        header += le(UInt32(36 + pcm.count))
        header += Data("WAVEfmt ".utf8)
        header += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        header += le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16))
        header += Data("data".utf8)
        header += le(UInt32(pcm.count))
        return header + pcm
    }

    private static let page = """
    <!doctype html><html><body><script>
    const post = (o) => webkit.messageHandlers.peer.postMessage(o);
    let ctx, pc, speech, dest, pcm = [], loud = false;
    async function start(file, record) {
      let track;
      if (file || record) { ctx = new AudioContext({ sampleRate: 24000 }); await ctx.resume(); }
      if (file) {
        speech = await ctx.decodeAudioData(Uint8Array.from(atob(file), c => c.charCodeAt(0)).buffer);
        dest = ctx.createMediaStreamDestination(); track = dest.stream.getAudioTracks()[0];
      } else {
        const mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
        track = mic.getAudioTracks()[0];
      }
      pc = new RTCPeerConnection();
      pc.addTrack(track);
      pc.createDataChannel("oai-events");
      pc.onconnectionstatechange = () => post({ kind: "state", state: pc.connectionState });
      pc.ontrack = (e) => {
        const out = new Audio(); out.srcObject = e.streams[0] || new MediaStream([e.track]); out.muted = record; out.play();
        if (!record) return;
        const tap = ctx.createScriptProcessor(1024, 1, 1);
        tap.onaudioprocess = (ev) => {
          const d = ev.inputBuffer.getChannelData(0), s = new Int16Array(d.length);
          let peak = 0;
          for (let i = 0; i < d.length; i++) { peak = Math.max(peak, Math.abs(d[i])); s[i] = Math.max(-1, Math.min(1, d[i])) * 32767; }
          if ((peak > 0.02) !== loud) { loud = !loud; post({ kind: "output", loud }); }
          pcm.push(s);
        };
        ctx.createMediaStreamSource(out.srcObject).connect(tap); tap.connect(ctx.destination);
      };
      await pc.setLocalDescription(await pc.createOffer());
      await new Promise((done) => {
        if (pc.iceGatheringState === "complete") return done();
        pc.onicegatheringstatechange = () => pc.iceGatheringState === "complete" && done();
        setTimeout(done, 2000);
      });
      return pc.localDescription.sdp;
    }
    async function answer(sdp) { await pc.setRemoteDescription({ type: "answer", sdp }); }
    function play() { const s = ctx.createBufferSource(); s.buffer = speech; s.connect(dest); s.onended = () => post({ kind: "inputEnded" }); s.start(); }
    function dump() {
      let n = 0; for (const c of pcm) n += c.length;
      const all = new Int16Array(n); let o = 0; for (const c of pcm) { all.set(c, o); o += c.length; }
      const u8 = new Uint8Array(all.buffer); let s = "";
      for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
      return btoa(s);
    }
    function close() { if (pc) pc.close(); if (ctx) ctx.close(); }
    post({ kind: "ready" });
    </script></body></html>
    """
}

enum VoicePeerError: Error { case noOffer }

extension VoicePeer: WKUIDelegate {
    /// 只有这一页、只要麦克风：直接给（系统那一层的麦克风权限照常弹一次）。
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }
}

/// 网页的消息处理器被 WebKit 强引用：经它弱引用回去，连接关了 `VoicePeer` 照常释放。
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var peer: VoicePeer?
    init(_ peer: VoicePeer) { self.peer = peer }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { peer?.receive(message.body) }
    }
}
#endif
