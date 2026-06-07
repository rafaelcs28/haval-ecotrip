//  MapPickerSheet.swift
//  Escolher o destino tocando no mapa (pino), com tipo de mapa padrão/híbrido/satélite.
//  Retorna a coordenada + nome reverso-geocodificado.

import SwiftUI
import MapKit

struct MapPickerSheet: View {
    var start: CLLocationCoordinate2D
    var initial: CLLocationCoordinate2D? = nil       // pino já posicionado (vindo da busca)
    var onPick: (CLLocationCoordinate2D, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var coord: CLLocationCoordinate2D?
    @State private var mapType: MKMapType = .hybrid
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PickerMap(start: initial ?? start, initialSet: initial != nil, mapType: mapType, coord: $coord)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 10) {
                    Picker("", selection: $mapType) {
                        Text("Padrão").tag(MKMapType.standard)
                        Text("Híbrido").tag(MKMapType.hybrid)
                        Text("Satélite").tag(MKMapType.satellite)
                    }.pickerStyle(.segmented)

                    if let c = coord {
                        if !name.isEmpty {
                            Text(name).font(.callout).foregroundStyle(DS.text).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DSActionButton(icon: "mappin.and.ellipse", title: "Usar este ponto", color: DS.teal) {
                            onPick(c, name.isEmpty ? String(format: "%.5f, %.5f", c.latitude, c.longitude) : name)
                            dismiss()
                        }
                    } else {
                        Text("Toque no mapa para marcar o destino")
                            .font(.callout).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(12)
            }
            .navigationTitle("Escolher no mapa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .onChange(of: coordKey) { _, _ in reverseGeocode() }
        }
    }

    private var coordKey: String { coord.map { "\($0.latitude),\($0.longitude)" } ?? "" }

    private func reverseGeocode() {
        guard let c = coord else { name = ""; return }
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { places, _ in
            guard let p = places?.first else { return }
            var line = p.name ?? ""
            if line.isEmpty, let r = p.thoroughfare { line = r; if let n = p.subThoroughfare { line += ", \(n)" } }
            if let b = p.subLocality, !b.isEmpty, !line.contains(b) { line += line.isEmpty ? b : " · \(b)" }
            DispatchQueue.main.async { name = line }
        }
    }
}

// MKMapView com toque pra marcar o destino. Tipo de mapa controlado de fora.
private struct PickerMap: UIViewRepresentable {
    var start: CLLocationCoordinate2D
    var initialSet: Bool = false
    var mapType: MKMapType
    @Binding var coord: CLLocationCoordinate2D?

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.mapType = mapType
        mv.showsCompass = false
        let span = initialSet ? 1500.0 : 6000.0
        mv.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: span, longitudinalMeters: span), animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.onTap(_:)))
        mv.addGestureRecognizer(tap)
        context.coordinator.map = mv
        // Pino inicial vindo da busca (mais zoom pra ajustar fino).
        if initialSet {
            let ann = MKPointAnnotation(); ann.coordinate = start; ann.title = "Destino"
            mv.addAnnotation(ann)
            DispatchQueue.main.async { coord = start }
        }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        if mv.mapType != mapType { mv.mapType = mapType }
    }

    final class Coord: NSObject {
        let parent: PickerMap
        weak var map: MKMapView?
        init(_ p: PickerMap) { parent = p }
        @objc func onTap(_ g: UITapGestureRecognizer) {
            guard let mv = map else { return }
            let pt = g.location(in: mv)
            let c = mv.convert(pt, toCoordinateFrom: mv)
            mv.removeAnnotations(mv.annotations)
            let ann = MKPointAnnotation(); ann.coordinate = c; ann.title = "Destino"
            mv.addAnnotation(ann)
            parent.coord = c
        }
    }
}
