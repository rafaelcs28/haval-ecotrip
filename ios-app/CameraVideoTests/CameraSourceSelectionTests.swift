import XCTest

final class CameraSourceSelectionTests: XCTestCase {
    func testSelectingCurrentSourceDoesNothing() {
        XCTAssertEqual(CameraSourceSelectionPolicy.stopAction(from: .haval, to: .haval), .none)
        XCTAssertEqual(CameraSourceSelectionPolicy.stopAction(from: .dashcam, to: .dashcam), .none)
    }

    func testSwitchingStopsOnlyCurrentSource() {
        XCTAssertEqual(CameraSourceSelectionPolicy.stopAction(from: .haval, to: .dashcam), .stopHaval)
        XCTAssertEqual(CameraSourceSelectionPolicy.stopAction(from: .dashcam, to: .haval), .stopDashcam)
    }
}
