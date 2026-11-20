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
        XCTAssertEqual(place.chargeMeters.count, 1)
    }

    func testKnownPlaceDecodesMixedChargeMeterList() {
        let place = KnownPlace([
            "id": "mixed",
            "name": "Shopping",
            "lat": -16.0,
            "lng": -49.0,
            "charge_meters": [
                [
                    "enabled": true,
                    "provider": "zeeda",
                    "charger_id": "Z-1",
                    "charger_name": "Zeeda 1",
                    "tariffs": [["effective_from_ms": 1_700_000_000_000, "price_per_kwh": 0.18]]
                ],
                [
                    "enabled": true,
                    "provider": "zeeda",
                    "charger_id": "Z-2",
                    "charger_name": "Zeeda 2",
                    "tariffs": [["effective_from_ms": 1_800_000_000_000, "price_per_kwh": 0.32]]
                ],
                [
                    "enabled": true,
                    "provider": "yellotmob",
                    "charger_id": "273",
                    "charger_name": "Yellot",
                    "tariffs": []
                ]
            ]
        ])

        XCTAssertEqual(place.chargeMeters.map(\.key), ["zeeda:z-1", "zeeda:z-2", "yellotmob:273"])
        XCTAssertEqual(place.chargeMeters[0].currentPricePerKwh, 0.18)
        XCTAssertEqual(place.chargeMeters[1].currentPricePerKwh, 0.32)
        XCTAssertEqual(place.chargeMeter?.chargerId, "Z-1")
    }

    func testEmptyCanonicalMeterListDoesNotFallBackToLegacyMeter() {
        let place = KnownPlace([
            "id": "empty",
            "name": "Empty",
            "lat": 1.0,
            "lng": 1.0,
            "charge_meters": [],
            "charge_meter": [
                "enabled": true,
                "provider": "yellotmob",
                "charger_id": "legacy",
                "charger_name": "Legacy",
                "tariffs": []
            ]
        ])

        XCTAssertTrue(place.chargeMeters.isEmpty)
        XCTAssertNil(place.chargeMeter)
    }

    func testChargeMeterKeysRejectNormalizedDuplicates() throws {
        let first = ChargeMeterConfig(enabled: true, provider: " ZEEDA ", chargerId: " AbC ", chargerName: "A")
        let duplicate = ChargeMeterConfig(enabled: true, provider: "zeeda", chargerId: "abc", chargerName: "B")

        XCTAssertEqual(first.key, "zeeda:abc")
        XCTAssertThrowsError(try ChargeMeterConfig.validateUnique([first, duplicate])) { error in
            XCTAssertEqual(error as? ChargeMeterConfigError, .duplicateCharger)
        }
    }

    func testProviderGroupsRoundTripWithoutLosingTariffs() {
        let configs = [
            ChargeMeterConfig(
                enabled: true,
                provider: "zeeda",
                chargerId: "Z-1",
                chargerName: "Zeeda 1",
                tariffs: [ChargeMeterTariff(effectiveFromMs: 1000, pricePerKwh: 0.18)]
            ),
            ChargeMeterConfig(enabled: true, provider: "yellotmob", chargerId: "Y-1", chargerName: "Yellot 1"),
            ChargeMeterConfig(
                enabled: true,
                provider: "zeeda",
                chargerId: "Z-2",
                chargerName: "Zeeda 2",
                tariffs: [ChargeMeterTariff(effectiveFromMs: 2000, pricePerKwh: 0.32)]
            )
        ]

        let groups = ChargeMeterProviderGroup.group(configs)

        XCTAssertEqual(groups.map(\.provider), ["zeeda", "yellotmob"])
        XCTAssertEqual(groups[0].meters.map(\.chargerId), ["Z-1", "Z-2"])
        XCTAssertEqual(ChargeMeterProviderGroup.flatten(groups), [configs[0], configs[2], configs[1]])
        XCTAssertEqual(groups[0].meters.map(\.currentPricePerKwh), [0.18, 0.32])
    }

    func testApplyingMultipleSelectionPreservesExistingTariffAndAddsNewMeter() {
        let existing = ChargeMeterConfig(
            enabled: true,
            provider: "zeeda",
            chargerId: "Z-1",
            chargerName: "Existing",
            tariffs: [ChargeMeterTariff(effectiveFromMs: 1000, pricePerKwh: 0.18)]
        )
        let group = ChargeMeterProviderGroup(provider: "zeeda", meters: [existing])
        let catalog = [
            ChargeMeterCharger(["id": "Z-1", "name": "Existing"])!,
            ChargeMeterCharger(["id": "Z-2", "name": "New"])!
        ]

        let expanded = group.applyingSelection(["Z-1", "Z-2"], catalog: catalog)
        XCTAssertEqual(expanded.meters.map(\.chargerId), ["Z-1", "Z-2"])
        XCTAssertEqual(expanded.meters[0].currentPricePerKwh, 0.18)
        XCTAssertTrue(expanded.meters[1].tariffs.isEmpty)

        let reduced = expanded.applyingSelection(["Z-2"], catalog: catalog)
        XCTAssertEqual(reduced.meters.map(\.chargerId), ["Z-2"])
    }

    func testRemovingProviderGroupKeepsOtherProviders() {
        let groups = [
            ChargeMeterProviderGroup(provider: "zeeda", meters: [
                ChargeMeterConfig(enabled: true, provider: "zeeda", chargerId: "Z-1", chargerName: "Zeeda")
            ]),
            ChargeMeterProviderGroup(provider: "yellotmob", meters: [
                ChargeMeterConfig(enabled: true, provider: "yellotmob", chargerId: "Y-1", chargerName: "Yellot")
            ])
        ]

        XCTAssertEqual(ChargeMeterProviderGroup.removing("zeeda", from: groups).map(\.provider), ["yellotmob"])
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

    func testLiveEnergyComparisonCalculatesChargingLoss() {
        let comparison = ChargeEnergyComparison(chargerEnergyKwh: 14.115, vehicleEnergyKwh: 12.48)

        XCTAssertEqual(comparison?.lossKwh ?? -1, 1.635, accuracy: 0.0001)
        XCTAssertEqual(comparison?.lossPercent ?? -1, 11.5834, accuracy: 0.001)
        XCTAssertNil(ChargeEnergyComparison(chargerEnergyKwh: 0, vehicleEnergyKwh: 12.48))
    }

    func testChargeActivityDecodesPayloadWithoutExternalMeterFields() throws {
        let data = #"{"soc":67,"powerKw":50.93,"sessionKwh":12.48,"remainingMin":20,"charging":true,"targetPct":100,"updatedAtMs":1795194000000}"#.data(using: .utf8)!

        let state = try JSONDecoder().decode(ChargeActivityAttributes.ContentState.self, from: data)

        XCTAssertNil(state.chargerPowerKw)
        XCTAssertNil(state.chargerSessionKwh)
        XCTAssertNil(state.costBrl)
    }

    func testPendingProviderCostIsNotPresentedAsFree() {
        let charge = Charge([
            "timestamp_ms": 1_795_185_674_311,
            "energy_kwh": 24.14,
            "charge_meter_reconcile": ["status": "pending"]
        ])

        XCTAssertTrue(charge.costPending)
        XCTAssertFalse(charge.isFree)
        XCTAssertEqual(charge.costTotal, 0)
    }

    func testFailedProviderCostIsNotPresentedAsCalculatingForever() {
        let charge = Charge([
            "timestamp_ms": 1_795_185_674_311,
            "energy_kwh": 24.14,
            "charge_meter_reconcile": ["status": "failed"]
        ])

        XCTAssertFalse(charge.costPending)
        XCTAssertFalse(charge.isFree)
        XCTAssertEqual(charge.costTotal, 0)
    }
}
