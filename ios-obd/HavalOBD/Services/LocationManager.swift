import Foundation
import CoreLocation

/// Fonte de GPS do iPad pro cluster. Publica lat/lng/speed/heading no snapshot
/// pra o cluster.html centralizar o marker e o widget de speed reaproveitar.
///
/// Permissão: `NSLocationWhenInUseUsageDescription` no Info.plist.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published var lat: Double?
    @Published var lng: Double?
    @Published var headingDeg: Double?     // 0 = norte, 90 = leste
    @Published var speedKmh: Double?       // velocidade pelo GPS
    @Published var authorized = false
    @Published var lastFixAt: Date?

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?    // pra calcular speed manualmente se loc.speed < 0

    override init() {
        super.init()
        manager.delegate = self
        // BestForNavigation usa sensores extras (giroscópio, acelerômetro) +
        // GPS pra precisão sub-3m e updates contínuos enquanto move. Necessário
        // pro cluster mostrar km/h fluido (a 60 km/h = 16 m/s).
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone   // todo update
        manager.activityType = .automotiveNavigation
    }

    func start() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            authorized = true
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.authorized = true
                manager.startUpdatingLocation()
                manager.startUpdatingHeading()
            } else {
                self.authorized = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let la = loc.coordinate.latitude
        let lo = loc.coordinate.longitude
        Task { @MainActor in
            // Speed: prefere loc.speed (oficial CoreLocation), senão calcula
            // a partir da distância pra última posição. Em iPad com GPS frio
            // loc.speed às vezes vem -1 por minutos — fallback evita travamento.
            var kmh: Double? = nil
            if loc.speed >= 0 {
                kmh = loc.speed * 3.6
            } else if let prev = self.lastLocation {
                let dist = loc.distance(from: prev)   // metros
                let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
                if dt > 0.1, dt < 10, dist >= 0 {
                    kmh = (dist / dt) * 3.6
                }
            }
            self.lat = la
            self.lng = lo
            self.speedKmh = kmh
            self.lastFixAt = Date()
            self.lastLocation = loc
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.headingDeg = h }
    }
}
