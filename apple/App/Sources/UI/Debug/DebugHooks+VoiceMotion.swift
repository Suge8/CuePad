import QuartzCore

extension DebugHooks {
    /// 声纹播放门的现场取证；只在显式启动参数下记状态变化，不记音量或每帧日志。
    static func voiceRibbon(_ ribbon: VoiceRibbon, on layer: CALayer) {
        #if DEBUG
        guard DebugScene.defaults.bool(forKey: "CuePadVoiceMotionTrace") else { return }
        let loops = (layer.sublayers ?? []).filter { $0.animation(forKey: "loop") != nil }.count
        let line = "voice-ribbon activity=\(String(describing: ribbon.activity)) playing=\(ribbon.playing) reduced=\(ribbon.reduced) loops=\(loops)"
        let id = ObjectIdentifier(layer)
        if voiceRibbonDiagnostics[id] != line {
            voiceRibbonDiagnostics[id] = line
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        #endif
    }

    #if DEBUG
    private static var voiceRibbonDiagnostics: [ObjectIdentifier: String] = [:]
    #endif
}
