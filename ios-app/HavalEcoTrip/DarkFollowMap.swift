//  DarkFollowMap.swift
//  Mapa escuro (tiles CartoDB dark — mesmo do cluster do iPad) que segue o carro:
//  zoom adaptativo por velocidade, pan/zoom manual e reenquadre automático após 10s.

import SwiftUI
import MapKit

struct DarkFollowMap: UIViewRepresentable {
    var lat: Double
    var lng: Double
    var heading: Double = 0
    var speedKmh: Double = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.overrideUserInterfaceStyle = .dark
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = false
        // Tiles dark (CartoDB) substituindo o basemap da Apple — igual ao iPad.
        let overlay = MKTileOverlay(urlTemplate: "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png")
        overlay.canReplaceMapContent = true
        mv.addOverlay(overlay, level: .aboveLabels)

        let ann = MKPointAnnotation()
        ann.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        mv.addAnnotation(ann)
        context.coordinator.carAnn = ann
        context.coordinator.map = mv

        for g in [UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userTouched)),
                  UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userTouched)) as UIGestureRecognizer] {
            g.delegate = context.coordinator
            mv.addGestureRecognizer(g)
        }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        context.coordinator.carAnn?.coordinate = c
        context.coordinator.heading = heading
        context.coordinator.lastSpeed = speedKmh
        if let v = context.coordinator.carAnn.flatMap({ mv.view(for: $0) }) {
            v.transform = CGAffineTransform(rotationAngle: CGFloat(heading) * .pi / 180)
        }
        if context.coordinator.autoFollow { context.coordinator.recenter(c, speedKmh: speedKmh) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var map: MKMapView?
        var carAnn: MKPointAnnotation?
        var autoFollow = true
        var lastTouch = Date.distantPast
        var heading = 0.0
        var lastSpeed = 0.0
        private var timer: Timer?

        override init() {
            super.init()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, !self.autoFollow, Date().timeIntervalSince(self.lastTouch) > 10 else { return }
                self.autoFollow = true
                if let c = self.carAnn?.coordinate { self.recenter(c, speedKmh: self.lastSpeed) }
            }
        }
        deinit { timer?.invalidate() }

        @objc func userTouched() { autoFollow = false; lastTouch = Date() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        func recenter(_ c: CLLocationCoordinate2D, speedKmh: Double) {
            guard let map else { return }
            // parado ~0,004; mais rápido = mais afastado (lookahead), teto ~0,03.
            let span = min(0.03, max(0.0035, 0.004 + speedKmh / 120 * 0.02))
            map.setRegion(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)), animated: true)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let id = "car"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.image = Coordinator.carImage
            v.transform = CGAffineTransform(rotationAngle: CGFloat(heading) * .pi / 180)
            return v
        }
        @MainActor static let carImage: UIImage = {
            let r = ImageRenderer(content: CarMarker(size: 30))
            r.scale = UIScreen.main.scale
            return r.uiImage ?? UIImage()
        }()
    }
}
