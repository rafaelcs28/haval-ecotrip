enum CameraLiveSource: String, CaseIterable {
    case haval = "Haval"
    case dashcam = "Dashcam"
}

enum CameraSourceStopAction: Equatable {
    case none
    case stopHaval
    case stopDashcam
}

enum CameraSourceSelectionPolicy {
    static func stopAction(from current: CameraLiveSource, to next: CameraLiveSource) -> CameraSourceStopAction {
        guard current != next else { return .none }
        return current == .haval ? .stopHaval : .stopDashcam
    }
}
