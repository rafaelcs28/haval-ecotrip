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
    @State private var confirmHonk = false
    @State private var flashing = false
    @State private var userDistance: Double?   // metros até o carro (se houver localização do usuário)
    @State private var showCompass = false
    @StateObject private var compass = CompassLocator()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let s = parking.spot { content(s) } else { emptyState }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Onde estacionei")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.muted) }
                }
            }
            .onAppear { note = parking.spot?.note ?? ""; geocode(); compass.start(); parking.resyncNote() }
            .onDisappear { compass.stop() }
            .onChange(of: parking.spot) { _, _ in note = parking.spot?.note ?? ""; geocode() }
            .alert("Limpar estacionamento?", isPresented: $confirmClear) {
                Button("Limpar", role: .destructive) { parking.clear() }
                Button("Cancelar", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func content(_ s: ParkingSpot) -> some View {
        VStack(spacing: 16) {
            // Header: título + tempo desde que estacionou.
            HStack {
                Text("Onde estacionei").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text)
                Spacer()
                DSChip(text: relativeTime(s.ts), color: DS.teal)
            }

            // Alterna mapa / bússola ao vivo (seta apontando o carro).
            Picker("", selection: $showCompass) {
                Label("Mapa", systemImage: "map.fill").tag(false)
                Label("Bússola", systemImage: "location.north.line.fill").tag(true)
            }
            .pickerStyle(.segmented)

            if showCompass {
                ParkingCompass(carLat: s.lat, carLng: s.lng, compass: compass)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(DS.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            } else {
                // Mini-mapa: pino do carro + ponto azul do usuário + distância.
                ParkingMap(lat: s.lat, lng: s.lng, distance: $userDistance)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if let d = userDistance {
                            Text(d < 1000 ? "\(Int(d)) m" : Fmt.dec1(d / 1000) + " km")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(DS.panel.opacity(0.85)).clipShape(Capsule())
                                .padding(8)
                        }
                    }
            }

            // Local + nota (andar/vaga) editável, com botão de foto (visual).
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "location.fill").font(.system(size: 12)).foregroundStyle(DS.green)
                    Text(address.isEmpty ? "Local salvo" : address).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 11)
                Rectangle().fill(DS.divider).frame(height: 1)
                HStack(spacing: 8) {
                    Image(systemName: "note.text").font(.system(size: 12)).foregroundStyle(DS.muted)
                    TextField("vaga 214 · anotado por você", text: $note)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(DS.text)
                        .onSubmit { parking.setNote(note) }
                        .onChange(of: note) { _, v in parking.setNote(v) }
                }
                .padding(.vertical, 11)
            }
            .padding(.horizontal, 12)
            .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            // CTAs: navegar a pé (verde) + piscar (comando).
            HStack(spacing: 10) {
                Button { openWalking(s.coordinate) } label: {
                    HStack(spacing: 6) { Image(systemName: "figure.walk"); Text("Ir até o carro") }
                        .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 42)
                        .foregroundStyle(.black).background(DS.green).clipShape(Capsule())
                }.buttonStyle(.plain)
                Button { flashFind() } label: {
                    HStack(spacing: 6) {
                        if flashing { ProgressView().tint(DS.yellow) } else { Image(systemName: "lightbulb.fill") }
                        Text(flashing ? "Piscando" : "Piscar")
                    }
                    .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(DS.yellow).background(DS.yellow.opacity(0.12)).clipShape(Capsule())
                    .overlay(Capsule().stroke(DS.yellow.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain).disabled(flashing)
                // Long-press = piscar + buzinar (confirmação, por ser mais intrusivo).
                .onLongPressGesture { if !flashing { confirmHonk = true } }
                .confirmationDialog("Piscar e buzinar?", isPresented: $confirmHonk, titleVisibility: .visible) {
                    Button("Piscar e buzinar") { flashFind(honk: true) }
                    Button("Cancelar", role: .cancel) {}
                } message: { Text("Segure para localizar com buzina; toque simples só pisca.") }
            }

            HStack(spacing: 10) {
                if car.hasGps {
                    DSActionButton(icon: "arrow.clockwise", title: "Atualizar local", color: DS.blue, compact: true) {
                        parking.saveCurrent(lat: car.lat, lng: car.lng)
                    }
                }
                DSActionButton(icon: "trash.fill", title: "Limpar", color: DS.red, compact: true) { confirmClear = true }
            }

            Text("Salvo automaticamente ao desligar · some ao dirigir de novo.")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "parkingsign.circle").font(.system(size: 44)).foregroundStyle(DS.muted)
            Text("Nenhum estacionamento salvo").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
            Text("O local é salvo automaticamente quando o carro desliga.")
                .font(.system(size: 12)).foregroundStyle(DS.muted).multilineTextAlignment(.center)
            if car.hasGps {
                DSActionButton(icon: "parkingsign", title: "Salvar local atual do carro", color: DS.teal) {
                    parking.saveCurrent(lat: car.lat, lng: car.lng)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .padding(.horizontal, 14)
        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // "Encontrar meu carro": comando de find-car da nuvem GWM (0x06) — pisca os
    // faróis + buzinada curta e ACORDA o carro remotamente, ao contrário do pisca
    // local (IVehicle), que exige o app do carro acordado (falha no estacionamento).
    private func flashFind(honk: Bool = false) {
        guard !flashing else { return }
        flashing = true
        Task {
            _ = await CarStore.shared.action(honk ? "find_car_honk" : "find_car")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            flashing = false
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

// Fornece heading (bússola) + localização do usuário ao vivo pra seta apontar
// o carro independente de como o telefone está virado.
final class CompassLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var heading: Double?                    // rumo do topo do celular (0=N)
    @Published var userLoc: CLLocationCoordinate2D?
    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        mgr.headingFilter = 2
    }
    func start() {
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { mgr.startUpdatingHeading() }
    }
    func stop() { mgr.stopUpdatingHeading(); mgr.stopUpdatingLocation() }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        let v = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        DispatchQueue.main.async { self.heading = v }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        DispatchQueue.main.async { self.userLoc = c }
    }
}

// Bússola: seta grande que gira em tempo real pra apontar o carro. Ângulo =
// rumo(usuário→carro) − heading do celular. Aponte o topo e siga a seta.
private struct ParkingCompass: View {
    let carLat: Double; let carLng: Double
    @ObservedObject var compass: CompassLocator

    private var bearingToCar: Double? {
        guard let u = compass.userLoc else { return nil }
        let lat1 = u.latitude * .pi / 180, lat2 = carLat * .pi / 180
        let dLng = (carLng - u.longitude) * .pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    private var distance: Double? {
        guard let u = compass.userLoc else { return nil }
        return CLLocation(latitude: u.latitude, longitude: u.longitude)
            .distance(from: CLLocation(latitude: carLat, longitude: carLng))
    }

    var body: some View {
        let b = bearingToCar
        let rot = (b ?? 0) - (compass.heading ?? 0)
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(DS.divider, lineWidth: 1)
                Circle().stroke(DS.green.opacity(0.25), lineWidth: 1).padding(18)
                if b == nil {
                    ProgressView().tint(DS.muted)
                } else {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(DS.green)
                        .rotationEffect(.degrees(rot))
                        .animation(.easeOut(duration: 0.2), value: rot)
                }
            }
            .frame(width: 132, height: 132)

            if let d = distance {
                Text(d < 1000 ? "\(Int(d)) m" : Fmt.dec1(d / 1000) + " km")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text)
            }
            Text(compass.heading == nil
                 ? "Calibrando a bússola…"
                 : "Aponte o topo do celular e siga a seta")
                .font(.system(size: 11)).foregroundStyle(DS.muted)
        }
        .padding(.vertical, 12)
    }
}

// Mapa escuro com o pino do carro (tiles CartoDB) + ponto azul do usuário e
// distância (só aparece se o app já tiver permissão de localização).
private struct ParkingMap: UIViewRepresentable {
    var lat: Double; var lng: Double
    @Binding var distance: Double?

    func makeCoordinator() -> Coord { Coord(self) }
    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.overrideUserInterfaceStyle = .dark
        mv.pointOfInterestFilter = .excludingAll
        mv.isRotateEnabled = false; mv.showsCompass = false
        mv.showsUserLocation = true
        let overlay = MKTileOverlay(urlTemplate: "https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png")
        overlay.canReplaceMapContent = true
        mv.addOverlay(overlay, level: .aboveLabels)
        let ann = MKPointAnnotation(); ann.coordinate = .init(latitude: lat, longitude: lng); ann.title = "Carro"
        mv.addAnnotation(ann)
        mv.setRegion(MKCoordinateRegion(center: ann.coordinate, latitudinalMeters: 280, longitudinalMeters: 280), animated: false)
        return mv
    }
    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.parent = self
        guard let ann = mv.annotations.compactMap({ $0 as? MKPointAnnotation }).first else { return }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        ann.coordinate = c
        mv.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 280, longitudinalMeters: 280), animated: true)
    }
    final class Coord: NSObject, MKMapViewDelegate {
        var parent: ParkingMap
        init(_ p: ParkingMap) { parent = p }
        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            (o as? MKTileOverlay).map { MKTileOverlayRenderer(tileOverlay: $0) } ?? MKOverlayRenderer(overlay: o)
        }
        func mapView(_ m: MKMapView, didUpdate userLocation: MKUserLocation) {
            let loc = userLocation.location
            guard let loc, loc.horizontalAccuracy >= 0 else { return }
            let car = CLLocation(latitude: parent.lat, longitude: parent.lng)
            let d = loc.distance(from: car)
            DispatchQueue.main.async { self.parent.distance = d }
        }
    }
}
