import QuartzCore

extension DebugHooks {
    static func voiceRibbon(_ ribbon: VoiceRibbon, on layer: VoiceRibbonLayer) {
        #if DEBUG
        guard DebugScene.args.voiceOpts.motionTrace else { return }
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
