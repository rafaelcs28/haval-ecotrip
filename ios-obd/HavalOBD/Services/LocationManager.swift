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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5   // metros
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
        let s  = loc.speed >= 0 ? loc.speed * 3.6 : nil   // m/s → km/h
        Task { @MainActor in
            self.lat = la
            self.lng = lo
            self.speedKmh = s
            self.lastFixAt = Date()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.headingDeg = h }
    }
}
