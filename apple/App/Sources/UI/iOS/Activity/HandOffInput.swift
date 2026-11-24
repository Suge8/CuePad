#if os(iOS)
import CueStore
import SwiftUI

struct HandOffInput: View {
    let outbox: Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var digest: SessionDigest?
    @State private var choice: UUID?
    @State private var fresh = false
    @State private var planned: HandOffTargets.Options?
    @State private var launchAgents: MacAgents?
    @FocusState private var focused: Bool

    private var sessions: [SessionListItem] {
        HandOffTargets.sessions(services.sessionFeed.live, project: outbox.project, bound: planned?.bound, at: services.speech)
    }
    private var chosen: SessionListItem? {
        guard !fresh else { return nil }
        let all = sessions
        if let choice { return all.first { $0.state.id == choice } }
        return planned?.bound.flatMap { bound in all.first { $0.state.sessionID == bound.state.sessionID } }
    }
    private var launching: SessionLaunching { workspace.sessionLaunching(outbox.launchKey) }
    private var waiting: Bool { launching.inFlight(at: services.speech) }
    private var launchStatus: LaunchStatus? {
        let noMac = planned?.noMac == true
        guard chosen == nil || noMac || waiting else { return nil }
        return LaunchStatus(noMac: noMac, phase: launching.phase(at: services.speech), agents: launchAgents)
    }
    private var canSend: Bool {
        guard !waiting, planned.map({ !$0.noMac }) == true else { return false }
        return chosen != nil || launchTools != nil && launching.canSubmit(at: services.speech)
    }

    private var box: Binding<ComposerDraft> {
        let workspace = workspace, outbox = outbox
        return Binding(get: { workspace.handOffDraft }) { draft in
            workspace.handOffDraft = draft
            if workspace.outbox == nil, !draft.isEmpty(accepting: [.files, .cards]) { workspace.outbox = outbox }
        }
    }
    private var chosenLive: SessionState? {
        guard let chosen = chosen?.state else { return nil }
        return services.sessionFeed.live.contains { $0.state.id == chosen.id } ? chosen : nil
    }
    private var chosenDigest: SessionDigest? {
        guard let digest, let id = chosenLive?.id, digest.session?.id == id else { return nil }
        return digest
    }
    private var config: ConfigShown? { chosenDigest?.config(at: services.speech) }
    private var catalog: AgentCatalog? { chosenDigest?.catalog }
    private var commands: [SlashCommand] { chosen == nil ? [] : catalog?.commands ?? [] }

    private var tools: (session: SessionState, models: [ModelOption], config: ConfigShown)? {
        guard let session = chosen?.state, let config, let models = catalog?.models, !models.isEmpty else { return nil }
        return (session, models, config)
    }
    private var launchPlan: HandOffPlan? { chosen != nil ? nil : fresh ? planned?.fresh : planned?.plan }
    private var launchSpot: (project: UUID, host: String)? {
        guard case .launch(let project, let host) = launchPlan?.destination else { return nil }
        return (project, host)
    }
    private var launchHost: String? { launchSpot?.host }
    private var launchTools: MacAgents? {
        launchAgents.flatMap { services.settings.launchChoice(on: $0, in: launchSpot?.project) == nil ? nil : $0 }
    }

    var body: some View {
        Composer(
            draft: box, prompt: "补一句", label: "发给 Agent", focus: $focused,
            accepts: chosen == nil ? [.files, .cards] : .reply, cardsFrom: outbox.project, keeps: outbox.card, tooled: tools != nil || launchTools != nil,
            commands: commands, submit: send,
            header: { header.padding(.horizontal, Spacing.group).padding(.top, Spacing.item) },
            tools: {
                if let tools {
                    SessionConfigControls(session: tools.session, models: tools.models, shown: tools.config)
                } else if let launchTools {
                    LaunchControls(mac: launchTools, project: launchSpot?.project)
                }
            },
            send: {
                Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canSend)
                    .accessibilityLabel(chosen.map { String(localized: "交给 \($0.state.title)") } ?? String(localized: "开新会话交给它"))
            })
        .composerNotice(launchStatus != nil || config?.failure != nil) {
            if let launchStatus { LaunchStatusLine(status: launchStatus) } else { MacInputNotice(noMac: false, failure: config?.failure) }
        }
        .disabled(waiting)
        .confirmsLaunchAgain(launching)
        .onAppear { focused = true }
        .observing(services.store, id: outbox.card, into: $planned, onError: workspace.fail) { [card = outbox.card] store in
            try HandOffTargets.Options(card, in: store)
        }
        .observingLaunchAgents(id: launchHost, into: $launchAgents, onError: workspace.fail) { [host = launchHost] _ in host }
        .observing(services.store, id: chosenLive, into: $digest, onError: workspace.fail) { [session = chosenLive] store in
            guard let session else { return SessionDigest(session: nil, project: nil, deliveries: []) }
            return SessionDigest(
                session: session, project: nil, deliveries: try store.deliveryRequests(toSession: session.sessionID),
                catalog: try store.catalog(of: session))
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.item) {
            MenuButton(sections: [
                ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "新会话", image: .icon(.add), checked: chosen == nil) { fresh = true }]),
                ChoiceMenu.Section(choices: sessions.map { item in
                    ChoiceMenu.Choice(title: .verbatim(title(item).visible), checked: item.state.id == chosen?.state.id) {
                        choice = item.state.id
                        fresh = false
                    }
                }),
            ], accessibilityLabel: chosen.map { "交给 \($0.state.title)，点开换会话" } ?? "交给新会话") {
                DestinationChip(title: Text(chosen.map { "交给 \($0.state.title)" } ?? "交给 新会话")) {
                    if let chosen { StateDot(shown: workspace.shown(chosen), size: 7) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ item: SessionListItem) -> Dotted {
        HandOffTargets.title(item, project: workspace.catalog?.project(item.state.projectID), shown: workspace.shown(item))
    }

    private func send() {
        guard canSend else { return }
        guard let session = chosen?.state else {
            workspace.launchHandOff(outbox, opening: planned?.opening)
            return
        }
        let sent = workspace.reply(
            to: session, commands: commands, from: box, accepting: .reply, card: outbox.card, saying: Dotted(String(localized: "已交给 \(session.title)")))
        workspace.answer { _ in await sent.value }
        focused = false
        workspace.outbox = nil
    }
}
#endif
