import CueStore

extension AppServices {
    func updateCue(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await store.updateCueProfile(edit)
    }

    func enableCue(on host: String, moving: Bool) async throws {
        guard syncing.knowsSyncedFacts else { throw CueEnableError.unsynced }
        #if os(macOS)
        if host == hostID { try await macAgents.record() }
        #endif
        try await store.enableCue(on: host, moving: moving)
        #if os(iOS)
        await alerts?.requestAuthorization()
        #endif
    }

    func turnCue(_ on: Bool, here: String?) async throws {
        guard on else { return try await updateCue { $0.enabledAt = nil } }
        guard let host = try await CueSettings.read(from: store).resumeHost(here: here) else { throw CueEnableError.noMac }
        try await enableCue(on: host.id, moving: false)
    }

    var cueOnDutyHere: Bool {
        #if os(macOS)
        cue.onDuty
        #else
        false
        #endif
    }
}
