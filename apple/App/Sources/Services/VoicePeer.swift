#if os(macOS)
import AppKit
import WebKit

/// 实时语音的媒体那一头：系统 WebKit 里的一个 WebRTC 连接（`RTCPeerConnection`），声音进出都在这里，信令与控制在 `VoiceCall`。
/// 选 WebKit 不另引 libwebrtc：订阅的语音只给 WebRTC（WebSocket 要 API Key），WebKit 自带完整 ICE，UDP 不通时自己用 TCP 连服务器的 443 候选，
/// Opus 编解码由 WebKit 提供；通话会创建一个 WebContent 进程。请求回声消除、降噪与自动增益约束，不代表 WebKit 都支持或实际启用。
/// 本机实测 supportedConstraints 不含 noiseSuppression、autoGainControl；实际处理须核对支持列表与轨道 settings，不能由请求值推断。
/// 网页要挂进一扇系统认为"看得见"的窗：WebKit 只在挂进窗口的网页里让 AudioContext 跑起来，页面被遮住（屏外的窗也算被遮住）时
/// getUserMedia 一直挂着、不去问麦克风权限。所以是一扇屏内左下角、全透明、不接鼠标、浮在普通窗口之上的 8 点小窗（透明不算遮住，实测）。
/// 声音来源二选一：麦克风（`getUserMedia`，要麦克风权限；给了设备名就用名字含它的那个输入，不然用系统默认的），
/// 或一段音频文件（`play` 时播进连接，无人值守的验收用）；给了 `recording` 时把对方的声音录成 24 kHz 单声道 WAV（`close` 时写出），这时不外放。
/// 两头各挂一个电平表（`AnalyserNode`，每 50 毫秒取一次峰值）：过阈值报响起，低于阈值满 300 毫秒报停下并带这一段的峰值（`Event.level`）。
@MainActor
final class VoicePeer: NSObject {
    enum Source { case microphone(device: String?), file(URL) }
    enum Side: String { case input, output }
    enum Event: Equatable {
        case connected, failed
        /// 文件播完了
        case inputEnded
        /// 麦克风来源实际用上的输入设备（名字）
        case device(String)
        /// 你这边（input）或对方（output）的声音响起、停下；停下时 `peak` 是这一段的峰值（0～1），响起时为当下的
        case level(Side, loud: Bool, peak: Double)
    }

    var onEvent: (Event) -> Void = { _ in }
    private let source: Source
    private let recording: URL?
    private let web: WKWebView
    private let window: NSWindow
    private var closed = false
    private var ready = false
    private var operations: [UUID: CheckedContinuation<String?, Error>] = [:]

    init(source: Source, recording: URL?) {
        self.source = source
        self.recording = recording
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 8, height: 8), configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "peer")
        web.uiDelegate = self
        web.navigationDelegate = self
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.orderFrontRegardless()
    }

    /// 起连接、收集完本机候选（不逐个送出：服务器一次收下整份），返回要交给服务器的 SDP。
    func offer() async throws -> String {
        try await load()
        try Task.checkCancellation()
        try await DebugHooks.configureVoice(web, source: source)
        try Task.checkCancellation()
        var file: Any = NSNull(), device: Any = NSNull()
        switch source {
        case .file(let url): file = try Data(contentsOf: url).base64EncodedString()
        case .microphone(let name): device = name ?? NSNull()
        }
        let sdp = try await javascript(
            "return await start(file, device, record)", arguments: ["file": file, "device": device, "record": recording != nil])
        guard let sdp else { throw VoicePeerError.noOffer }
        return sdp
    }

    func accept(answer: String) async throws {
        _ = try await javascript("return await answer(sdp)", arguments: ["sdp": answer])
    }

    /// 文件来源：从现在起播进连接，播完报 `inputEnded`。
    func play() async throws {
        _ = try await javascript("return play()")
    }

    /// 整次通话里你这边声音的最大峰值（0～1）：一次也没响起时看它是没声还是太弱。
    func inputMax() async -> Double {
        (try? await javascript("return String(inputMax)")).flatMap(Double.init) ?? 0
    }

    /// 先撤销还在等的 JS / 权限请求；关闭文档会终止未返回的 getUserMedia，晚回来的 callback 不再恢复 continuation。
    func close() async throws {
        guard !closed else { return }
        defer { shutDown() }
        if ready, operations.isEmpty, let recording {
            guard let pcm = try await javascript("close(); return dump()"), let data = Data(base64Encoded: pcm) else { throw VoicePeerError.noRecording }
            try Self.wav(data).write(to: recording)
        }
    }

    private func shutDown() {
        guard !closed else { return }
        closed = true
        loaded?.finish()
        loaded = nil
        let pending = operations.values
        operations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        window.close()
    }

    private func javascript(_ body: String, arguments: [String: Any] = [:]) async throws -> String? {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                operations[id] = continuation
                web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
                    guard let continuation = self?.operations.removeValue(forKey: id) else { return }
                    continuation.resume(with: result.map { $0 as? String })
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.shutDown() }
        }
    }

    private func load() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let signal = AsyncStream<Void>.makeStream()
        loaded = signal.continuation
        // https 的源才算安全上下文；页面不联网，源只是个名字。
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://voice.cuepad.invalid/"))
        try await withTaskCancellationHandler {
            for await _ in signal.stream { break }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } onCancel: {
            Task { @MainActor [weak self] in self?.shutDown() }
        }
    }

    private var loaded: AsyncStream<Void>.Continuation?

    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready": ready = true; loaded?.yield(); loaded?.finish(); loaded = nil
        case "state":
            switch body["state"] as? String {
            case "connected": onEvent(.connected)
            case "failed", "disconnected", "closed": if !closed { onEvent(.failed) }
            default: break
            }
        case "inputEnded": onEvent(.inputEnded)
        case "device": onEvent(.device(body["label"] as? String ?? ""))
        case "level":
            guard let side = (body["side"] as? String).flatMap(Side.init) else { return }
            onEvent(.level(side, loud: body["loud"] as? Bool == true, peak: body["peak"] as? Double ?? 0))
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
    let ctx, pc, speech, dest, localTrack, pcm = [], inputMax = 0;
    const meters = [], levelThreshold = 0.02, sampleMs = 50, quietMs = 300;
    // 电平表：每 50 毫秒取峰值，过 0.02 报响起，低于它满 300 毫秒报停下（带这一段的峰值）
    function meter(stream, side) {
      const an = ctx.createAnalyser(); an.fftSize = 1024; ctx.createMediaStreamSource(stream).connect(an);
      const buf = new Float32Array(an.fftSize);
      let loud = false, quietFor = 0, span = 0;
      meters.push(setInterval(() => {
        an.getFloatTimeDomainData(buf);
        let peak = 0; for (const v of buf) peak = Math.max(peak, Math.abs(v));
        if (side === "input") inputMax = Math.max(inputMax, peak);
        if (peak > levelThreshold) {
          quietFor = 0; span = Math.max(span, peak);
          if (!loud) { loud = true; post({ kind: "level", side, loud, peak }); }
        } else if (loud && (quietFor += sampleMs) >= quietMs) {
          loud = false; post({ kind: "level", side, loud, peak: span }); span = 0;
        }
      }, sampleMs));
    }
    const audio = { echoCancellation: true, noiseSuppression: true, autoGainControl: true };
    async function microphone(device) {
      let mic = await navigator.mediaDevices.getUserMedia({ audio });
      if (!device) return mic;
      // 设备名要授权之后才读得到：先用默认的开一次，按名字找到再换
      const inputs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === "audioinput");
      const found = inputs.find(d => d.label.includes(device));
      mic.getTracks().forEach(t => t.stop());
      if (!found) throw new Error("没有名字含 " + device + " 的输入：" + inputs.map(d => d.label).join("、"));
      return await navigator.mediaDevices.getUserMedia({ audio: { ...audio, deviceId: { exact: found.deviceId } } });
    }
    async function start(file, device, record) {
      let track;
      ctx = new AudioContext({ sampleRate: 24000 }); await ctx.resume();
      if (file) {
        speech = await ctx.decodeAudioData(Uint8Array.from(atob(file), c => c.charCodeAt(0)).buffer);
        dest = ctx.createMediaStreamDestination(); track = dest.stream.getAudioTracks()[0];
      } else {
        track = (await microphone(device)).getAudioTracks()[0];
        post({ kind: "device", label: track.label + " " + JSON.stringify({ settings: track.getSettings(), supported: navigator.mediaDevices.getSupportedConstraints() }) });
      }
      localTrack = track;
      meter(new MediaStream([track]), "input");
      pc = new RTCPeerConnection();
      pc.addTrack(track);
      pc.createDataChannel("oai-events");
      pc.onconnectionstatechange = () => post({ kind: "state", state: pc.connectionState });
      pc.ontrack = (e) => {
        const out = new Audio(); out.srcObject = e.streams[0] || new MediaStream([e.track]); out.muted = record; out.play();
        meter(out.srcObject, "output");
        if (!record) return;
        const tap = ctx.createScriptProcessor(1024, 1, 1);
        tap.onaudioprocess = (ev) => {
          const d = ev.inputBuffer.getChannelData(0), s = new Int16Array(d.length);
          for (let i = 0; i < d.length; i++) s[i] = Math.max(-1, Math.min(1, d[i])) * 32767;
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
    function close() { meters.forEach(clearInterval); localTrack?.stop(); if (pc) pc.close(); if (ctx) ctx.close(); }
    post({ kind: "ready" });
    </script></body></html>
    """
}

enum VoicePeerError: Error { case noOffer, noRecording }

extension VoicePeer: WKUIDelegate, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { mediaFailed() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { mediaFailed() }

    private func mediaFailed() {
        guard !closed else { return }
        onEvent(.failed)
        shutDown()
    }

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
