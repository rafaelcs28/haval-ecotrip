//  BydMiniMap.swift
//  Mini-mapa escuro (tiles CartoDB dark, igual ao Haval Hub) que segue o BYD em tempo
//  real, com zoom manual e reenquadre automático após 10s.

import SwiftUI
import MapKit

struct BydMiniMap: UIViewRepresentable {
    var lat: Double
    var lng: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.overrideUserInterfaceStyle = .dark
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = false
        let overlay = MKTileOverlay(urlTemplate: "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png")
        overlay.canReplaceMapContent = true
        mv.addOverlay(overlay, level: .aboveLabels)

        let ann = MKPointAnnotation()
        ann.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        mv.addAnnotation(ann)
        context.coordinator.carAnn = ann
        context.coordinator.map = mv

        for g in [UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched)),
                  UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched)) as UIGestureRecognizer] {
            g.delegate = context.coordinator
            mv.addGestureRecognizer(g)
        }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        context.coordinator.carAnn?.coordinate = c
        if context.coordinator.autoFollow { context.coordinator.recenter(c) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var map: MKMapView?
        var carAnn: MKPointAnnotation?
        var autoFollow = true
        var lastTouch = Date.distantPast
        private var timer: Timer?

        override init() {
            super.init()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, !self.autoFollow, Date().timeIntervalSince(self.lastTouch) > 10 else { return }
                self.autoFollow = true
                if let c = self.carAnn?.coordinate { self.recenter(c) }
            }
        }
        deinit { timer?.invalidate() }

        @objc func touched() { autoFollow = false; lastTouch = Date() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        func recenter(_ c: CLLocationCoordinate2D) {
            map?.setRegion(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)), animated: true)
        }

        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            (o as? MKTileOverlay).map { MKTileOverlayRenderer(tileOverlay: $0) } ?? MKOverlayRenderer(overlay: o)
        }
        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            let id = "byd"
            let v = m.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
            v.image = Coordinator.carImage
            v.annotation = a
            return v
        }
        static let carImage: UIImage = {
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
            return UIImage(systemName: "car.fill", withConfiguration: cfg)?
                .withTintColor(UIColor.white, renderingMode: .alwaysOriginal) ?? UIImage()
        }()
    }
}
