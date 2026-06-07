//  ParkingSheet.swift
//  "Onde estacionei": mapa com o pino do carro, há quanto tempo, endereço, nota
//  (andar/vaga) e botão pra abrir a navegação a pé até o carro.

import SwiftUI
import MapKit

struct ParkingSheet: View {
    @ObservedObject var parking = ParkingStore.shared
    @ObservedObject var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var address = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let s = parking.spot { content(s) } else { emptyState }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Onde estacionei")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .onAppear { note = parking.spot?.note ?? ""; geocode() }
            .onChange(of: parking.spot) { _, _ in note = parking.spot?.note ?? ""; geocode() }
            .alert("Limpar estacionamento?", isPresented: $confirmClear) {
                Button("Limpar", role: .destructive) { parking.clear() }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func content(_ s: ParkingSpot) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                ParkingMap(lat: s.lat, lng: s.lng)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 6) {
                    Image(systemName: "parkingsign.circle.fill").foregroundStyle(DS.teal)
                    Text("Estacionado \(relativeTime(s.ts))").font(.headline).foregroundStyle(DS.text)
                }
                if !address.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill").font(.caption2).foregroundStyle(DS.green)
                        Text(address).font(.callout).foregroundStyle(DS.muted)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "note.text").font(.subheadline).foregroundStyle(DS.muted)
                    TextField("Andar / vaga (ex: G2 · vaga 14)", text: $note)
                        .textFieldStyle(.plain).foregroundStyle(DS.text)
                        .onSubmit { parking.setNote(note) }
                        .onChange(of: note) { _, v in parking.setNote(v) }
                }
                .padding(12).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                DSActionButton(icon: "figure.walk", title: "Levar até o carro", color: DS.teal) {
                    openWalking(s.coordinate)
                }
                HStack(spacing: 10) {
                    if car.hasGps {
                        DSActionButton(icon: "arrow.clockwise", title: "Atualizar local", color: DS.blue) {
                            parking.saveCurrent(lat: car.lat, lng: car.lng)
                        }
                    }
                    DSActionButton(icon: "trash.fill", title: "Limpar", color: DS.red) { confirmClear = true }
                }
            }
        }
    }

    private var emptyState: some View {
        DSCard {
            VStack(spacing: 12) {
                Image(systemName: "parkingsign.circle").font(.system(size: 44)).foregroundStyle(DS.muted)
                Text("Nenhum estacionamento salvo").font(.headline).foregroundStyle(DS.text)
                Text("O local é salvo automaticamente quando o carro desliga.")
                    .font(.callout).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                if car.hasGps {
                    DSActionButton(icon: "parkingsign", title: "Salvar local atual do carro", color: DS.teal) {
                        parking.saveCurrent(lat: car.lat, lng: car.lng)
                    }
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }

    private func openWalking(_ c: CLLocationCoordinate2D) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = "Carro"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func relativeTime(_ ts: Double) -> String {
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "pt_BR"); f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }

    private func geocode() {
        guard let s = parking.spot else { address = ""; return }
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: s.lat, longitude: s.lng)) { places, _ in
            guard let p = places?.first else { return }
            var line = p.thoroughfare ?? ""
            if let n = p.subThoroughfare, !line.isEmpty { line += ", \(n)" }
            if let b = p.subLocality, !b.isEmpty { line += line.isEmpty ? b : " · \(b)" }
            DispatchQueue.main.async { address = line }
        }
    }
}

// Mapa escuro estático com o pino do carro (tiles CartoDB, igual ao painel).
private struct ParkingMap: UIViewRepresentable {
    var lat: Double; var lng: Double

    func makeCoordinator() -> Coord { Coord() }
    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.overrideUserInterfaceStyle = .dark
        mv.pointOfInterestFilter = .excludingAll
        mv.isRotateEnabled = false; mv.showsCompass = false
        let overlay = MKTileOverlay(urlTemplate: "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png")
        overlay.canReplaceMapContent = true
        mv.addOverlay(overlay, level: .aboveLabels)
        let ann = MKPointAnnotation(); ann.coordinate = .init(latitude: lat, longitude: lng); ann.title = "Carro"
        mv.addAnnotation(ann)
        mv.setRegion(MKCoordinateRegion(center: ann.coordinate, latitudinalMeters: 280, longitudinalMeters: 280), animated: false)
        return mv
    }
    func updateUIView(_ mv: MKMapView, context: Context) {
        guard let ann = mv.annotations.compactMap({ $0 as? MKPointAnnotation }).first else { return }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        ann.coordinate = c
        mv.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 280, longitudinalMeters: 280), animated: true)
    }
    final class Coord: NSObject, MKMapViewDelegate {
        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            (o as? MKTileOverlay).map { MKTileOverlayRenderer(tileOverlay: $0) } ?? MKOverlayRenderer(overlay: o)
        }
    }
}
