import Foundation

@MainActor
final class CameraRoutePolicy {
    enum Decision: Equatable {
        case useLAN
        case askInternet
        case offline
    }

    private(set) var internetAllowed = false
    private var actionActive = false

    func beginAction(lanAvailable: Bool) -> Decision {
        actionActive = true
        internetAllowed = false
        return lanAvailable ? .useLAN : .askInternet
    }

    func lanAvailable() -> Decision {
        guard actionActive else { return .offline }
        internetAllowed = false
        return .useLAN
    }

    func lanUnavailable() -> Decision {
        guard actionActive else { return .offline }
        return internetAllowed ? .offline : .askInternet
    }

    func confirmInternet() {
        guard actionActive else { return }
        internetAllowed = true
    }

    func refuseInternet() -> Decision {
        stop()
        return .offline
    }

    func stop() {
        actionActive = false
        internetAllowed = false
    }
}
