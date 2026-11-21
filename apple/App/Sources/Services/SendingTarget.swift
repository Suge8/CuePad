import CueStore

struct SendingTarget: Hashable {
    private enum Place: Hashable {
        case cue
        case session(host: String, ref: String)
        case named(host: String, name: String)
    }

    private let place: Place
    static let cue = Self(place: .cue)

    init(host: String, target: SendTarget) {
        place = target.ref.map { .session(host: host, ref: $0) } ?? .named(host: host, name: target.name)
    }

    private init(place: Place) { self.place = place }
}
