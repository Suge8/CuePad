import AVFoundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一轮独占一份 WKWebView、权限/JS 等待、音轨和音频上下文；不重开已关闭的实例。
/// 页面导航不决定通话生死，所有者是 AppServices 的通话服务。关闭先撤销等待、显式停止轨道，再卸载网页。
/// iOS 的采集/播放会话由 WebKit 管理，本机不另外激活或停用音频会话：原生激活会被 WebKit 媒体会话打断。
final class VoicePeer: NSObject, VoiceMedia {
    static let sampleCount = 36
    enum Source { case microphone(device: String?), file(URL) }
    enum Side: String { case input, output }
    enum Event: Equatable {
        case connected, failed, inputEnded
        case ended(VoiceEndReason)
        case device(String)
        case level(Side, loud: Bool, peak: Double)
        case sample(Side, peak: Double)
    }
    var onEvent: (Event) -> Void = { _ in }
    let session: UUID
    private let source: Source
    private let recording: URL?
    private let web: WKWebView
    private let scope = VoiceOperationScope()
    private let loaded = AsyncStream<Void>.makeStream()
    private var closing: Task<Void, Error>?
    private var documentReady = false
    #if os(iOS)
    private var audioObservers: [NSObjectProtocol] = []
    #endif
    #if os(macOS)
    private let window: NSWindow
    #endif
    private static let cleanupLimit: Duration = .seconds(2)

    init(source: Source, recording: URL?, session: UUID = UUID()) {
        self.source = source
        self.recording = recording
        self.session = session
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 8, height: 8), configuration: config)
        #if os(macOS)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        #endif
        super.init()
        config.userContentController.add(VoicePeerHandler(self), name: "peer")
        web.uiDelegate = self
        web.navigationDelegate = self
    }

    isolated deinit {
        #if os(iOS)
        audioObservers.forEach(NotificationCenter.default.removeObserver)
        #endif
    }

    func offer() async throws -> String {
        try Task.checkCancellation()
        guard !scope.ended else { throw CancellationError() }
        trace("offer-request")
        try attach()
        if case .microphone = source {
            trace("permission-request")
            let granted: Bool = try await scope.wait { finish in
                #if os(macOS)
                AVCaptureDevice.requestAccess(for: .audio) { granted in Task { @MainActor in finish(.success(granted)) } }
                #else
                AVAudioApplication.requestRecordPermission { granted in Task { @MainActor in finish(.success(granted)) } }
                #endif
            }
            trace(granted ? "permission-granted" : "permission-denied")
            guard granted else { throw VoicePeerError.microphoneDenied }
        }
        #if os(iOS)
        guard UIApplication.shared.applicationState != .background else { throw VoicePeerError.notForeground }
        #endif
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://voice.cuepad.invalid/"))
        for await _ in loaded.stream { break }
        try Task.checkCancellation()
        guard !scope.ended else { throw CancellationError() }
        #if os(macOS)
        try await scope.perform { try await DebugHooks.configureVoice(self.web, source: self.source) }
        #endif
        let file: Any, device: Any
        switch source {
        case .file(let url): file = try Data(contentsOf: url).base64EncodedString(); device = NSNull()
        case .microphone(let name): file = NSNull(); device = name ?? NSNull()
        }
        guard let offer = try await javascript("return await start(session, file, device, record)", arguments: [
            "session": session.uuidString, "file": file, "device": device, "record": recording != nil,
        ]) else { throw VoicePeerError.noOffer }
        trace("offer-ready")
        return offer
    }

    func accept(answer: String) async throws { _ = try await javascript("return await media.answer(sdp)", arguments: ["sdp": answer]) }
    func play() async throws { _ = try await javascript("return media.play()") }
    func setMuted(_ muted: Bool) async throws { _ = try await javascript("media.track.enabled = !muted", arguments: ["muted": muted]) }
    func inputMax() async -> Double { (try? await javascript("return String(media.inputMax)")).flatMap(Double.init) ?? 0 }

    func cancel() {
        trace("cancel")
        scope.end()
        loaded.continuation.finish()
        #if os(iOS)
        audioObservers.forEach(NotificationCenter.default.removeObserver)
        audioObservers = []
        #endif
    }

    func close() async throws {
        if let closing { return try await closing.value }
        cancel()
        let cleanup = Task {
            let work = VoiceOperationScope()
            work.spawn { do { try await Task.sleep(for: Self.cleanupLimit); work.end() } catch { } }
            trace("close-begin")
            defer { work.end(); detach(); trace("close-finished") }
            var failures: [String] = []
            if documentReady {
                do {
                    let result = try await javascript("return await shut()", in: work)
                    guard result == "closed" || result == "not-started" else { throw VoicePeerError.shutdownUnconfirmed }
                    trace("media-closed")
                    if let recording {
                        guard let pcm = try await javascript("return media.dump()", in: work), let data = Data(base64Encoded: pcm) else { throw VoicePeerError.noRecording }
                        try Self.wav(data).write(to: recording)
                    }
                } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { throw NSError(domain: "VoiceMediaShutdown", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
        }
        closing = cleanup
        try await cleanup.value
    }

    private func javascript(_ body: String, arguments: [String: Any] = [:], in owner: VoiceOperationScope? = nil) async throws -> String? {
        try await (owner ?? scope).wait { finish in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in finish(result.map { $0 as? String }) }
        }
    }

    private func attach() throws {
        #if os(macOS)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        #else
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { throw VoicePeerError.notForeground }
        let audio = AVAudioSession.sharedInstance()
        let names = [AVAudioSession.didBecomeActiveNotification, AVAudioSession.didBecomeInactiveNotification,
                     AVAudioSession.resumptionRecommendationNotification]
        audioObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: audio, queue: .main) { [weak self] notification in
                let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                let resume = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let shared = (notification.object as? AVAudioSession) === AVAudioSession.sharedInstance()
                MainActor.assumeIsolated {
                    guard let self, !self.scope.ended else { return }
                    self.traceAudio(name: name, context: context, resume: resume, shared: shared)
                    guard name == AVAudioSession.didBecomeInactiveNotification,
                          let context, context.source == .system, context.interruptionContext != nil else { return }
                    self.onEvent(.ended(.audioInterrupted))
                    self.cancel()
                }
            }
        }
        audioObservers += [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: UIApplication.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trace(name.rawValue) }
            }
        }
        trace("audio-observing")
        web.alpha = 0.01
        window.addSubview(web)
        #endif
    }

    private func detach() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "peer")
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        #if os(macOS)
        window.close()
        #else
        web.removeFromSuperview()
        #endif
    }

    fileprivate func receive(_ body: Any) {
        guard !scope.ended, let body = body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "ready" { documentReady = true; loaded.continuation.yield(); loaded.continuation.finish(); return }
        guard (body["session"] as? String).flatMap(UUID.init(uuidString:)) == session else { return }
        switch kind {
        case "diagnostic": trace("\(body["stage"] as? String ?? "unknown") webMs=\(body["webMs"] as? Double ?? 0)")
        case "audioInterrupted": onEvent(.ended(.audioInterrupted)); cancel()
        case "connected": onEvent(.connected)
        case "failed": onEvent(.failed)
        case "inputEnded": onEvent(.inputEnded)
        case "device": onEvent(.device(body["label"] as? String ?? ""))
        case "sample", "level":
            guard let side = (body["side"] as? String).flatMap(Side.init), let peak = body["peak"] as? Double else { return }
            onEvent(kind == "sample" ? .sample(side, peak: peak) : .level(side, loud: body["loud"] as? Bool == true, peak: peak))
        default: break
        }
    }
}

extension VoicePeer: WKUIDelegate, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onEvent(.failed); cancel() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onEvent(.failed); cancel() }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(!scope.ended && type == .microphone && origin.host == "voice.cuepad.invalid" ? .grant : .deny)
    }
}

private final class VoicePeerHandler: NSObject, WKScriptMessageHandler {
    weak var peer: VoicePeer?
    init(_ peer: VoicePeer) { self.peer = peer }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { peer?.receive(message.body) }
    }
}

enum VoicePeerError: Error { case noOffer, noRecording, microphoneDenied, shutdownUnconfirmed, notForeground }
