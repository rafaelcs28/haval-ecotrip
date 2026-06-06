//
//  BydPhoneLocation.swift
//  Reporta a localização do celular do monitor pro bridge, pra LA de viagem do
//  BYD mostrar a distância/ETA (de carro, menor caminho) do veículo até você.
//
//  Usa significant-location-change (funciona em background, baixo consumo, sem
//  barra azul) + updates padrão quando o app está em uso. O cálculo da rota é no
//  bridge (OSRM); aqui só mandamos lat/lng. Throttle de 20s pra não floodar.
//
import Foundation
import CoreLocation

@MainActor
final class BydPhoneLocation: NSObject, CLLocationManagerDelegate {
    static let shared = BydPhoneLocation()
    private let mgr = CLLocationManager()
    private var started = false
    private var active = false               // viagem em curso (ignição ligada) → modo fino
    private var lastSentMs: Double = 0

    private override init() { super.init(); mgr.delegate = self }

    func start() {
        guard !started else { return }
        started = true
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.requestWhenInUseAuthorization()
        // Pede "Sempre" pra reportar em background (LA na tela bloqueada).
        mgr.requestAlwaysAuthorization()
        mgr.startMonitoringSignificantLocationChanges()   // baseline econômico (background)
        mgr.startUpdatingLocation()
    }

    /// Liga/desliga o modo fino: durante a viagem (ignição ligada) reporta com mais
    /// frequência e granularidade (inclusive em background) pra distância/ETA até o
    /// carro acompanharem seu deslocamento; fora da viagem volta ao econômico.
    func setActive(_ on: Bool) {
        guard started, on != active else { return }
        active = on
        if on {
            mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            mgr.distanceFilter = 100                     // reporta a cada ~100 m
            mgr.allowsBackgroundLocationUpdates = true   // exige UIBackgroundModes: location
            mgr.pausesLocationUpdatesAutomatically = false
            mgr.startUpdatingLocation()
        } else {
            mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
            mgr.distanceFilter = kCLDistanceFilterNone
            mgr.allowsBackgroundLocationUpdates = false  // volta ao significant-change
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.report(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func report(_ loc: CLLocation) {
        let now = Date().timeIntervalSince1970 * 1000
        let throttle = active ? 12_000.0 : 20_000.0        // viagem ativa → reporta mais fino
        guard now - lastSentMs > throttle else { return }
        lastSentMs = now
        guard BydSettings.isConfigured,
              let url = URL(string: BydSettings.baseURL + "/api/phone-location") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
        ])
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
