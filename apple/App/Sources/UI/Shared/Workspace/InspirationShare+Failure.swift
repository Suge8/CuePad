import Foundation

extension InspirationShare {
    nonisolated enum Recovery {
        case close, edit, retry

        var label: String {
            switch self {
            case .close: String(localized: "知道了")
            case .edit: String(localized: "返回编辑")
            case .retry: String(localized: "重试")
            }
        }
    }

    nonisolated struct Problem {
        let message: String
        let recovery: Recovery

        init(_ error: any Error) {
            message = error.localizedDescription
            switch error {
            case Failure.noImages: recovery = .close
            case Failure.tooLong, Failure.image, MarkdownRemoteImage.Failure.invalidImage, MarkdownRemoteImage.Failure.unreachable: recovery = .edit
            case Failure.missing: recovery = .edit
            case MarkdownRemoteImage.Failure.unavailable: recovery = .retry
            case let error as URLError:
                recovery = [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                            .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(error.code) ? .retry : .edit
            default: recovery = .close
            }
        }
    }
}
