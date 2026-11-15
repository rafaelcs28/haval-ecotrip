import Foundation

struct ChargeLocationCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let lat: Double?
    let lng: Double?
    let knownPlaceId: String?

    init?(_ raw: [String: Any]) {
        guard let id = Self.string(raw["id"]), !id.isEmpty else { return nil }
        self.id = id
        name = ((raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Local de recarga"
        lat = Self.double(raw["lat"])
        lng = Self.double(raw["lng"])
        knownPlaceId = Self.string(raw["known_place_id"])
    }

    var canCreateKnownPlace: Bool {
        guard let lat, let lng else { return false }
        return lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng)
    }

    static func unlinked(_ locations: [ChargeLocationCandidate]) -> [ChargeLocationCandidate] {
        locations.filter { $0.knownPlaceId == nil }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
        if let value = value as? String, let number = Double(value), number.isFinite { return number }
        return nil
    }
}

struct ChargeMeterProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let requiresTariff: Bool

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = (raw["name"] as? String) ?? id
        requiresTariff = (raw["requires_tariff"] as? Bool) ?? (id.lowercased() == "zeeda")
    }
}

struct ChargeMeterCharger: Identifiable, Equatable {
    let id: String
    let name: String
    let online: Bool?

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = (raw["name"] as? String) ?? id
        online = raw["online"] as? Bool
    }
}

struct ChargeMeterTariff: Equatable {
    let effectiveFromMs: Int64
    let pricePerKwh: Double

    init(effectiveFromMs: Int64, pricePerKwh: Double) {
        self.effectiveFromMs = effectiveFromMs
        self.pricePerKwh = pricePerKwh
    }

    init?(_ raw: [String: Any]) {
        guard let effectiveFromMs = Self.int64(raw["effective_from_ms"]),
              let pricePerKwh = Self.double(raw["price_per_kwh"]),
              pricePerKwh.isFinite, pricePerKwh >= 0 else { return nil }
        self.init(effectiveFromMs: effectiveFromMs, pricePerKwh: pricePerKwh)
    }

    var json: [String: Any] {
        ["effective_from_ms": effectiveFromMs, "price_per_kwh": pricePerKwh]
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }
}

enum ChargeMeterConfigError: LocalizedError {
    case missingProvider
    case missingCharger
    case invalidTariff

    var errorDescription: String? {
        switch self {
        case .missingProvider: return "Escolha o provedor."
        case .missingCharger: return "Escolha o carregador."
        case .invalidTariff: return "Informe uma tarifa válida."
        }
    }
}

struct ChargeMeterConfig: Equatable {
    var enabled: Bool
    var provider: String
    var chargerId: String
    var chargerName: String
    var tariffs: [ChargeMeterTariff]

    init(
        enabled: Bool = false,
        provider: String = "",
        chargerId: String = "",
        chargerName: String = "",
        tariffs: [ChargeMeterTariff] = []
    ) {
        self.enabled = enabled
        self.provider = provider
        self.chargerId = chargerId
        self.chargerName = chargerName
        self.tariffs = tariffs.sorted { $0.effectiveFromMs < $1.effectiveFromMs }
    }

    init?(_ raw: [String: Any]) {
        guard let provider = raw["provider"] as? String,
              let chargerId = raw["charger_id"] as? String else { return nil }
        self.init(
            enabled: (raw["enabled"] as? Bool) ?? false,
            provider: provider,
            chargerId: chargerId,
            chargerName: (raw["charger_name"] as? String) ?? chargerId,
            tariffs: (raw["tariffs"] as? [[String: Any]] ?? []).compactMap(ChargeMeterTariff.init)
        )
    }

    var currentPricePerKwh: Double? { tariffs.last?.pricePerKwh }

    var json: [String: Any] {
        [
            "enabled": enabled,
            "provider": provider,
            "charger_id": chargerId,
            "charger_name": chargerName,
            "tariffs": tariffs.map(\.json)
        ]
    }

    func updating(
        enabled: Bool,
        provider: String,
        chargerId: String,
        chargerName: String,
        priceText: String,
        effectiveFromMs: Int64
    ) throws -> ChargeMeterConfig {
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chargerId = chargerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else { throw ChargeMeterConfigError.missingProvider }
        guard !chargerId.isEmpty else { throw ChargeMeterConfigError.missingCharger }

        var tariffs: [ChargeMeterTariff] = provider == "zeeda" ? self.tariffs : []
        if provider == "zeeda" {
            let normalized = priceText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            guard let price = Double(normalized), price.isFinite, price >= 0 else {
                throw ChargeMeterConfigError.invalidTariff
            }
            if tariffs.last?.pricePerKwh != price {
                tariffs.append(ChargeMeterTariff(effectiveFromMs: effectiveFromMs, pricePerKwh: price))
            }
        }

        return ChargeMeterConfig(
            enabled: enabled,
            provider: provider,
            chargerId: chargerId,
            chargerName: chargerName.trimmingCharacters(in: .whitespacesAndNewlines),
            tariffs: tariffs
        )
    }
}
