//  PhoneLocationReporter.swift
//  Reporta a posição do celular pro bridge (POST /api/phone-location) pra LA
//  "voltar ao carro" calcular distância/rumo corretos com o app fechado.
//
//  Baseline: significant-location-change (background, baixo consumo). Quando há
//  carro estacionado, monitora um geofence ao redor dele; ao SAIR do raio, entra
//  em modo fino (updates ~a cada 80m, background) pra a distância acompanhar você
//  a pé. Volta ao econômico ao reentrar no raio ou após 45min.
//
import Foundation
import CoreLocation
import Combine

@MainActor
final class PhoneLocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PhoneLocationReporter()
    private let mgr = CLLocationManager()
    private var started = false
    private var fine = false
    private var lastSentMs: Double = 0
    private var fineTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private let regionId = "parked-car"

    private override init() { super.init(); mgr.delegate = self }

    func start() {
        guard !started else { return }
        started = true
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.requestWhenInUseAuthorization()
        mgr.requestAlwaysAuthorization()   // necessário pra reportar em background
        mgr.startMonitoringSignificantLocationChanges()
        mgr.startUpdatingLocation()
        // Acompanha o local do carro: (re)cria o geofence quando muda ou some.
        ParkingStore.shared.$spot
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateRegion($0) }
            .store(in: &bag)
        updateRegion(ParkingStore.shared.spot)
    }

    private func updateRegion(_ spot: ParkingSpot?) {
        mgr.monitoredRegions
            .filter { $0.identifier == regionId }
            .forEach { mgr.stopMonitoring(for: $0) }
        guard let s = spot, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            setFine(false); return
        }
        let r = CLCircularRegion(center: s.coordinate, radius: 120, identifier: regionId)
        r.notifyOnEntry = true; r.notifyOnExit = true
        mgr.startMonitoring(for: r)
    }

    // Modo fino: updates frequentes em background (exige UIBackgroundModes: location).
    private func setFine(_ on: Bool) {
        guard started, on != fine else { return }
        fine = on
        fineTimer?.invalidate(); fineTimer = nil
        if on {
            mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            mgr.distanceFilter = 80
            mgr.allowsBackgroundLocationUpdates = true
            mgr.pausesLocationUpdatesAutomatically = false
            mgr.startUpdatingLocation()
            // Safety: sai do modo fino sozinho após 45min (bateria).
            fineTimer = Timer.scheduledTimer(withTimeInterval: 45 * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.setFine(false) }
            }
        } else {
            mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
            mgr.distanceFilter = kCLDistanceFilterNone
            mgr.allowsBackgroundLocationUpdates = false
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == regionId else { return }
        Task { @MainActor in self.setFine(true) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == regionId else { return }
        Task { @MainActor in self.setFine(false) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in self.report(loc) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    private func report(_ loc: CLLocation) {
        let now = Date().timeIntervalSince1970 * 1000
        let throttle = fine ? 12_000.0 : 30_000.0
        guard now - lastSentMs > throttle else { return }
        guard !Settings.notifDeviceId.isEmpty, Settings.isConfigured else { return }
        lastSentMs = now
        let body: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
            "device_id": Settings.notifDeviceId,
            "haval_owner": true,   // marca este device como o dono do Haval no bridge
        ]
        Task { await CarStore.shared.command("/api/phone-location", body: body) }
    }
}
