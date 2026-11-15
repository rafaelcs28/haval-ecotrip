import XCTest
@testable import HavalEcoTrip

final class ChargeMeterModelsTests: XCTestCase {
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
}
