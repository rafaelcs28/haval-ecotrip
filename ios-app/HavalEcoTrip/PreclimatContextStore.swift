//  PreclimatContextStore.swift
//  Consome /api/preclimat/context: temp da cabine (com idade do dado) + clima
//  local (OpenWeather) ou sensor externo do carro. Mostra no chip do
//  LeaveBySheet pra usuário ver o estado antes de armar a pré-clima.
//  O pré-check inteligente (decide acionar/pular) roda no bridge — aqui é só UI.

import Foundation

@MainActor
final class PreclimatContextStore: ObservableObject {
    struct Weather {
        let tempC: Double
        let feelsC: Double?
        let condition: String
    }

    @Published var cabinTempC: Double?
    @Published var cabinAgeMin: Int?
    @Published var cabinFresh = false
    @Published var carSensorTempC: Double?
    @Published var weather: Weather?

    var hasData: Bool { cabinTempC != nil || weather != nil || carSensorTempC != nil }

    func load() async {
        let base = BridgeRouter.shared.currentURL
        guard let url = URL(string: "\(base)/api/preclimat/context") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let cabin = j["cabin"] as? [String: Any] {
                cabinTempC = (cabin["tempC"] as? NSNumber)?.doubleValue
                if let ms = (cabin["ageMs"] as? NSNumber)?.doubleValue {
                    cabinAgeMin = max(0, Int(ms / 60_000))
                }
                cabinFresh = (cabin["fresh"] as? Bool) ?? false
            }
            if let cs = j["carSensor"] as? [String: Any] {
                carSensorTempC = (cs["tempC"] as? NSNumber)?.doubleValue
            }
            if let w = j["weather"] as? [String: Any], let t = (w["tempC"] as? NSNumber)?.doubleValue {
                weather = Weather(
                    tempC: t,
                    feelsC: (w["feelsC"] as? NSNumber)?.doubleValue,
                    condition: (w["condition"] as? String) ?? ""
                )
            }
        } catch {}
    }
}
