import XCTest

#if TASK7_IMPLEMENTED
@MainActor
final class CameraRoutePolicyTests: XCTestCase {
    func testSupportedLANIsPreferred() {
        let policy = CameraRoutePolicy()
        XCTAssertEqual(policy.beginAction(lanAvailable: true), .useLAN)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testInitialMissingLANAsksBeforeInternet() {
        let policy = CameraRoutePolicy()
        XCTAssertEqual(policy.beginAction(lanAvailable: false), .askInternet)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testMissingCapabilityIsUnsupported() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: true)
        XCTAssertEqual(policy.lanUnavailable(), .askInternet)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testLANAuthenticationFailureAsksBeforeInternet() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: true)
        XCTAssertEqual(policy.lanUnavailable(), .askInternet)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testRefusalLeavesActionOffline() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: false)
        XCTAssertEqual(policy.refuseInternet(), .offline)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testConsentIsScopedToOneAction() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: false)
        policy.confirmInternet()
        XCTAssertTrue(policy.internetAllowed)

        XCTAssertEqual(policy.beginAction(lanAvailable: false), .askInternet)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testRemoteReconnectWithinActionReusesConsent() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: false)
        policy.confirmInternet()

        XCTAssertTrue(policy.internetAllowed)
        XCTAssertTrue(policy.internetAllowed)
    }

    func testLANLossRequiresASecondConfirmation() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: false)
        policy.confirmInternet()
        XCTAssertEqual(policy.lanAvailable(), .useLAN)
        XCTAssertFalse(policy.internetAllowed)

        XCTAssertEqual(policy.lanUnavailable(), .askInternet)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testStopAndCancelInvalidateConsent() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: false)
        policy.confirmInternet()
        policy.stop()
        XCTAssertFalse(policy.internetAllowed)
        XCTAssertEqual(policy.lanUnavailable(), .offline)

        _ = policy.beginAction(lanAvailable: false)
        policy.confirmInternet()
        XCTAssertEqual(policy.refuseInternet(), .offline)
        XCTAssertFalse(policy.internetAllowed)
    }

    func testReturningToLANInvalidatesOldInternetConsent() {
        let policy = CameraRoutePolicy()
        _ = policy.beginAction(lanAvailable: false)
        policy.confirmInternet()

        XCTAssertEqual(policy.lanAvailable(), .useLAN)
        XCTAssertFalse(policy.internetAllowed)
    }
}
#else
final class CameraRoutePolicyTests: XCTestCase {
    func testTask7RoutePolicyIsNotImplementedYet() {
        XCTFail("Task 7 route policy is not implemented")
    }
}
#endif
