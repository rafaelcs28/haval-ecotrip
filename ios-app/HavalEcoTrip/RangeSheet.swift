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
        let u = BridgeRouter.shared.currentURL
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
    // Isócrona (estrada) só vale até 100 km (limite Mapbox); acima disso → círculo (linha reta).
    private var useCircles: Bool { store.failed || evKm > 100 || totalKm > 100 }

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
                        // Hero: total no mapa + split elétrico/combustão à direita.
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(Fmt.int(totalKm))
                                        .font(.system(size: 60, weight: .ultraLight, design: .rounded))
                                        .foregroundStyle(DS.text).monospacedDigit()
                                    Text("km").font(.system(size: 16)).foregroundStyle(DS.muted)
                                }
                                Text("ATÉ ONDE CHEGO").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DS.muted).tracking(0.5)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 8) {
                                splitValue("\(Int(evKm)) km", "elétricos", DS.green)
                                if iceKm > 0 { splitValue("\(Int(iceKm)) km", "a combustão", DS.orange) }
                            }
                        }

                        // Barra empilhada verde (EV) + laranja (combustão).
                        VStack(spacing: 6) {
                            GeometryReader { g in
                                let evFrac = totalKm > 0 ? evKm / totalKm : 0
                                HStack(spacing: 0) {
                                    Rectangle().fill(DS.green)
                                        .frame(width: max(0, g.size.width * CGFloat(evFrac)))
                                    Rectangle().fill(DS.orange)
                                }
                                .clipShape(Capsule())
                            }.frame(height: 10)
                            HStack {
                                Text("EV · SOC \(soc)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.green)
                                Spacer()
                                if iceKm > 0 {
                                    Text("GASOLINA").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.orange)
                                }
                            }
                        }

                        DSCard {
                            RangeMap(center: car.coordinate, contours: store.contours,
                                     evKm: evKm, totalKm: totalKm, useCircles: useCircles)
                                .frame(height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    if store.loading { ProgressView().padding(8) }
                                }
                        }

                        // Lista de fatores (fundo painel2, hairlines).
                        VStack(spacing: 0) {
                            infoRow(icon: "map",
                                    title: useCircles ? "Raio em linha reta" : "Alcance por estrada",
                                    sub: useCircles ? "por estrada o alcance é menor"
                                                    : "trânsito, relevo e clima alteram o real",
                                    value: nil, valueColor: DS.text)
                            Divider().background(DS.divider)
                            infoRow(icon: "gauge.with.dots.needle.bottom.50percent",
                                    title: "Alcance total estimado",
                                    sub: "EV + combustão com o SOC atual",
                                    value: "\(Int(totalKm)) km", valueColor: DS.text)
                        }
                        .background(DS.panel2)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                        Text("Pelo seu uso real, não o padrão de fábrica.")
                            .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Até onde chego")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task {
                // Só busca isócrona (estrada) quando ambos cabem no limite de 100 km;
                // acima disso usamos círculo (linha reta), sem chamada ao Mapbox.
                if car.hasGps && evKm > 0 && evKm <= 100 && totalKm <= 100 {
                    await store.load(lat: car.lat, lng: car.lng, evKm: evKm, totalKm: max(totalKm, evKm))
                }
            }
        }
    }

    private func splitValue(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(DS.muted)
        }
    }

    private func infoRow(icon: String, title: String, sub: String, value: String?, valueColor: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(DS.text2).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(DS.text)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(DS.muted)
            }
            Spacer()
            if let value {
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueColor).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
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
        var evRect = MKMapRect.null, allRect = MKMapRect.null
        // Overlays no nível aboveLabels (ACIMA do tile, que tem canReplaceMapContent;
        // senão a área fica escondida sob o mapa).
        func addCircle(_ km: Double, ev: Bool) {
            let c = MKCircle(center: center, radius: km * 1000)
            if ev { co.evIds.insert(ObjectIdentifier(c)) }
            mv.addOverlay(c, level: .aboveLabels)
            allRect = allRect.union(c.boundingMapRect); if ev { evRect = evRect.union(c.boundingMapRect) }
        }
        func addPoly(_ coords: [CLLocationCoordinate2D], ev: Bool) {
            let p = MKPolygon(coordinates: coords, count: coords.count)
            if ev { co.evIds.insert(ObjectIdentifier(p)) }
            mv.addOverlay(p, level: .aboveLabels)
            allRect = allRect.union(p.boundingMapRect); if ev { evRect = evRect.union(p.boundingMapRect) }
        }
        if useCircles || contours.isEmpty {
            if totalKm > evKm { addCircle(totalKm, ev: false) }
            if evKm > 0 { addCircle(evKm, ev: true) }
        } else {
            for c in contours.sorted(by: { $0.kind > $1.kind }) { addPoly(c.coords, ev: c.kind == 0) }
        }
        // Enquadra pela área ELÉTRICA (mais relevante); total pode extrapolar a tela.
        let fit = !evRect.isNull ? evRect : allRect
        if !fit.isNull {
            mv.setVisibleMapRect(fit, edgePadding: .init(top: 44, left: 40, bottom: 44, right: 40), animated: false)
        } else {
            mv.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 5000, longitudinalMeters: 5000), animated: false)
        }
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
