import XCTest
@testable import HavalEcoTrip

final class ChargeMeterModelsTests: XCTestCase {
    func testChargeLocationCandidateDecodesNumericIdentifiers() {
        let location = ChargeLocationCandidate([
            "id": 42,
            "name": "YellotMob | T-63",
            "lat": -16.701,
            "lng": -49.261,
            "known_place_id": 7
        ])

        XCTAssertEqual(location?.id, "42")
        XCTAssertEqual(location?.name, "YellotMob | T-63")
        XCTAssertEqual(location?.knownPlaceId, "7")
        XCTAssertEqual(location?.canCreateKnownPlace, true)
    }

    func testChargeLocationCandidateDecodesStringIdentifierWithoutLink() {
        let location = ChargeLocationCandidate([
            "id": "history-1",
            "name": "Garagem",
            "lat": -16.7,
            "lng": -49.2
        ])

        XCTAssertEqual(location?.id, "history-1")
        XCTAssertNil(location?.knownPlaceId)
    }

    func testChargeLocationCandidateCannotCreateKnownPlaceWithoutCoordinates() {
        let location = ChargeLocationCandidate([
            "id": 1,
            "name": "Sem GPS",
            "lat": NSNull(),
            "lng": NSNull()
        ])

        XCTAssertEqual(location?.lat, nil)
        XCTAssertEqual(location?.lng, nil)
        XCTAssertEqual(location?.canCreateKnownPlace, false)

        let sentinel = ChargeLocationCandidate(["id": 2, "name": "Sem GPS", "lat": 0, "lng": 0])
        XCTAssertEqual(sentinel?.canCreateKnownPlace, false)

        let equator = ChargeLocationCandidate(["id": 3, "name": "Equador", "lat": 0, "lng": 10])
        XCTAssertEqual(equator?.canCreateKnownPlace, true)
    }

    func testOnlyUnlinkedChargeLocationsNeedUserConfirmation() {
        let linked = ChargeLocationCandidate([
            "id": 1, "name": "Vinculado", "known_place_id": 10
        ])!
        let unlinked = ChargeLocationCandidate([
            "id": 2, "name": "Pendente"
        ])!

        XCTAssertEqual(ChargeLocationCandidate.unlinked([linked, unlinked]).map(\.id), ["2"])
    }

    func testKnownPlaceDecodesExistingMeterConfiguration() {
        let place = KnownPlace([
            "id": "lisboa",
            "name": "Jardins Lisboa",
            "lat": -16.0,
            "lng": -49.0,
            "charge_meter": [
                "enabled": true,
                "provider": "zeeda",
                "charger_id": "D42787B28BA6",
                "charger_name": "Jardins Lisboa",
                "tariffs": [["effective_from_ms": 1_700_000_000_000, "price_per_kwh": 0.18]]
            ]
        ])

        XCTAssertEqual(place.chargeMeter?.provider, "zeeda")
        XCTAssertEqual(place.chargeMeter?.chargerId, "D42787B28BA6")
        XCTAssertEqual(place.chargeMeter?.currentPricePerKwh, 0.18)
        XCTAssertEqual(place.chargeMeter?.tariffs.count, 1)
    }

    func testUpdatingPriceAcceptsCommaAndKeepsTariffHistory() throws {
        let existing = ChargeMeterConfig(
            enabled: true,
            provider: "zeeda",
            chargerId: "D42787B28BA6",
            chargerName: "Jardins Lisboa",
            tariffs: [ChargeMeterTariff(effectiveFromMs: 1_700_000_000_000, pricePerKwh: 0.18)]
        )

        let updated = try existing.updating(
            enabled: true,
            provider: "zeeda",
            chargerId: "D42787B28BA6",
            chargerName: "Jardins Lisboa",
            priceText: "0,20",
            effectiveFromMs: 1_800_000_000_000
        )

        XCTAssertEqual(updated.tariffs.map(\.pricePerKwh), [0.18, 0.20])
        XCTAssertEqual(updated.tariffs.map(\.effectiveFromMs), [1_700_000_000_000, 1_800_000_000_000])
    }

    func testKeepingSameZeedaPriceDoesNotCreateDuplicateTariff() throws {
        let existing = ChargeMeterConfig(
            enabled: true,
            provider: "zeeda",
            chargerId: "D42787B28BA6",
            chargerName: "Jardins Lisboa",
            tariffs: [ChargeMeterTariff(effectiveFromMs: 1_700_000_000_000, pricePerKwh: 0.18)]
        )

        let updated = try existing.updating(
            enabled: true,
            provider: "zeeda",
            chargerId: "D42787B28BA6",
            chargerName: "Jardins Lisboa",
            priceText: "0,18",
            effectiveFromMs: 1_800_000_000_000
        )

        XCTAssertEqual(updated.tariffs.count, 1)
    }

    func testYellotMobUsesProviderCostWithoutTariff() throws {
        let config = try ChargeMeterConfig().updating(
            enabled: true,
            provider: "yellotmob",
            chargerId: "charger-1",
            chargerName: "Centro",
            priceText: "",
            effectiveFromMs: 1_800_000_000_000
        )

        XCTAssertTrue(config.tariffs.isEmpty)
        XCTAssertNil(config.currentPricePerKwh)
    }

    func testProviderCatalogDecodesTariffCapability() {
        let zeeda = ChargeMeterProvider(["id": "zeeda", "name": "Zeeda", "requires_tariff": true])
        let yellot = ChargeMeterProvider(["id": "yellotmob", "name": "YellotMob", "requires_tariff": false])

        XCTAssertEqual(zeeda?.id, "zeeda")
        XCTAssertEqual(zeeda?.name, "Zeeda")
        XCTAssertEqual(zeeda?.requiresTariff, true)
        XCTAssertEqual(yellot?.requiresTariff, false)
    }

    func testChargerCatalogDecodesStableIdentifier() {
        let charger = ChargeMeterCharger(["id": "station-42", "name": "Shopping", "online": true])

        XCTAssertEqual(charger?.id, "station-42")
        XCTAssertEqual(charger?.name, "Shopping")
        XCTAssertEqual(charger?.online, true)
    }

    func testLivePowerComparisonCalculatesChargingLoss() {
        let comparison = ChargePowerComparison(chargerPowerKw: 6.2, vehiclePowerKw: 5.7)

        XCTAssertEqual(comparison?.lossPercent ?? -1, 8.0645, accuracy: 0.001)
        XCTAssertNil(ChargePowerComparison(chargerPowerKw: 0, vehiclePowerKw: 5.7))
    }
}
