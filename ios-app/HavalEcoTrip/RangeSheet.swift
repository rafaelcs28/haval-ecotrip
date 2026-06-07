//  RangeSheet.swift
//  "Alcance no mapa": até onde o carro chega com o SOC atual. Desenha o alcance
//  real por estrada (Mapbox Isochrone via bridge) — EV e EV+gasolina — com
//  fallback em círculo (raio em linha reta) se a isócrona não estiver disponível.

import SwiftUI
import MapKit

struct RangeContour { let coords: [CLLocationCoordinate2D]; let kind: Int }   // 0 = EV · 1 = total

@MainActor
final class RangeStore: ObservableObject {
    @Published var contours: [RangeContour] = []
    @Published var loading = false
    @Published var failed = false

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load(lat: Double, lng: Double, evKm: Double, totalKm: Double) async {
        guard !base.isEmpty, (lat != 0 || lng != 0), evKm > 0 else { failed = true; return }
        loading = true; failed = false; defer { loading = false }
        var comps = URLComponents(string: "\(base)/api/range-isochrone")
        comps?.queryItems = [.init(name: "lat", value: String(lat)), .init(name: "lng", value: String(lng)),
                             .init(name: "ev_km", value: String(Int(evKm))),
                             .init(name: "total_km", value: String(Int(totalKm)))]
        guard let url = comps?.url else { failed = true; return }
        var r = URLRequest(url: url); r.timeoutInterval = 15
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cs = j["contours"] as? [[String: Any]], !cs.isEmpty else { failed = true; return }
            // Mapbox devolve em ordem crescente de metros → menor = EV, maior = total.
            let sorted = cs.sorted { (($0["meters"] as? Double) ?? 0) < (($1["meters"] as? Double) ?? 0) }
            var out: [RangeContour] = []
            for (i, c) in sorted.enumerated() {
                guard let ring = c["ring"] as? [[String: Any]] else { continue }
                let coords = ring.compactMap { p -> CLLocationCoordinate2D? in
                    guard let la = p["lat"] as? Double, let lo = p["lng"] as? Double else { return nil }
                    return .init(latitude: la, longitude: lo)
                }
                if coords.count > 2 { out.append(RangeContour(coords: coords, kind: sorted.count == 1 ? 0 : i)) }
            }
            contours = out
            failed = out.isEmpty
        } catch { failed = true }
    }
}

struct RangeSheet: View {
    @ObservedObject var car = CarStore.shared
    @StateObject private var store = RangeStore()
    @Environment(\.dismiss) private var dismiss

    private var evKm: Double { car.num("range_ev_km") }
    private var iceKm: Double { car.num("range_ice_km") }
    private var totalKm: Double { evKm + iceKm }
    private var soc: Int { Int(car.socPct.rounded()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !car.hasGps || evKm <= 0 {
                        DSCard {
                            VStack(spacing: 10) {
                                Image(systemName: "map").font(.system(size: 40)).foregroundStyle(DS.muted)
                                Text(car.hasGps ? "Sem dados de autonomia ainda." : "Aguardando o GPS do carro.")
                                    .font(.callout).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                    } else {
                        DSCard {
                            VStack(alignment: .leading, spacing: 12) {
                                RangeMap(center: car.coordinate, contours: store.contours,
                                         evKm: evKm, totalKm: totalKm, useCircles: store.failed)
                                    .frame(height: 300)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        if store.loading { ProgressView().padding(8) }
                                    }
                                HStack(spacing: 16) {
                                    legend(color: DS.green, label: "Elétrico", value: "\(Int(evKm)) km")
                                    if iceKm > 0 { legend(color: DS.blue, label: "+ Gasolina", value: "\(Int(totalKm)) km") }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text("\(soc)%").font(.system(size: 22, weight: .bold, design: .rounded))
                                            .foregroundStyle(arrivalSocColor(soc))
                                        Text("SOC").font(.caption2).foregroundStyle(DS.muted)
                                    }
                                }
                                Text(store.failed
                                     ? "Raio aproximado em linha reta (isócrona indisponível). Por estrada chega menos."
                                     : "Alcance por estrada (Mapbox). Trânsito, relevo e clima alteram o real.")
                                    .font(.caption2).foregroundStyle(DS.muted)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Até onde chego")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task {
                if car.hasGps && evKm > 0 {
                    await store.load(lat: car.lat, lng: car.lng, evKm: evKm, totalKm: max(totalKm, evKm))
                }
            }
        }
    }

    private func legend(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                Text(label).font(.caption2).foregroundStyle(DS.muted)
            }
        }
    }
}

// Mapa escuro com os contornos de alcance (polígonos ou círculos de fallback).
private struct RangeMap: UIViewRepresentable {
    var center: CLLocationCoordinate2D
    var contours: [RangeContour]
    var evKm: Double
    var totalKm: Double
    var useCircles: Bool

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.overrideUserInterfaceStyle = .dark
        mv.pointOfInterestFilter = .excludingAll
        mv.showsCompass = false; mv.isRotateEnabled = false
        let tile = MKTileOverlay(urlTemplate: "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png")
        tile.canReplaceMapContent = true
        mv.addOverlay(tile, level: .aboveLabels)
        let ann = MKPointAnnotation(); ann.coordinate = center; mv.addAnnotation(ann)
        apply(mv, context.coordinator)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        if let ann = mv.annotations.compactMap({ $0 as? MKPointAnnotation }).first { ann.coordinate = center }
        apply(mv, context.coordinator)
    }

    private func apply(_ mv: MKMapView, _ co: Coord) {
        mv.overlays.forEach { if !($0 is MKTileOverlay) { mv.removeOverlay($0) } }
        co.evIds.removeAll()
        let maxKm = max(totalKm, evKm, 1)
        func addCircle(_ km: Double, ev: Bool) {
            let c = MKCircle(center: center, radius: km * 1000)
            if ev { co.evIds.insert(ObjectIdentifier(c)) }
            mv.addOverlay(c)
        }
        func addPoly(_ coords: [CLLocationCoordinate2D], ev: Bool) {
            let p = MKPolygon(coordinates: coords, count: coords.count)
            if ev { co.evIds.insert(ObjectIdentifier(p)) }
            mv.addOverlay(p)
        }
        if useCircles || contours.isEmpty {
            if totalKm > evKm { addCircle(totalKm, ev: false) }
            if evKm > 0 { addCircle(evKm, ev: true) }
        } else {
            for c in contours.sorted(by: { $0.kind > $1.kind }) { addPoly(c.coords, ev: c.kind == 0) }
        }
        let span = min(max((maxKm * 2.4) / 111.0, 0.02), 6.0)
        mv.setRegion(MKCoordinateRegion(center: center, span: .init(latitudeDelta: span, longitudeDelta: span)), animated: false)
    }

    final class Coord: NSObject, MKMapViewDelegate {
        var evIds = Set<ObjectIdentifier>()
        private let green = UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
        private let blue  = UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1)
        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            if let t = o as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            let isEv = evIds.contains(ObjectIdentifier(o as AnyObject))
            let col = isEv ? green : blue
            if let poly = o as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                r.fillColor = col.withAlphaComponent(isEv ? 0.20 : 0.10)
                r.strokeColor = col; r.lineWidth = 2.5
                return r
            }
            if let circ = o as? MKCircle {
                let r = MKCircleRenderer(circle: circ)
                r.fillColor = col.withAlphaComponent(isEv ? 0.16 : 0.08)
                r.strokeColor = col; r.lineWidth = 2.5
                return r
            }
            return MKOverlayRenderer(overlay: o)
        }
    }
}
