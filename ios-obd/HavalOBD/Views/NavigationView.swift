import SwiftUI
import MapKit

/// MapKit nativo que fica no FUNDO da tela do cluster (atrás do WebView
/// transparente). Substitui o Leaflet HTML quando rodando no app nativo.
/// Recebe a rota do NavigationService pra desenhar polyline + auto-fit.
struct ClusterMapView: View {
    @ObservedObject var nav: NavigationService
    @EnvironmentObject var location: LocationManager

    var body: some View {
        MapViewRepresentable(route: nav.route, userLocation: userCLL)
            .ignoresSafeArea()
    }

    private var userCLL: CLLocationCoordinate2D? {
        guard let la = location.lat, let lo = location.lng else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }
}

/// Overlay flutuante que aparece sobre o cluster quando o usuário clica
/// "Navegar". Tem search no topo + (se calculada) cartão de rota / guidance
/// no rodapé. Não cobre o cluster inteiro — só os 2 cantos.
struct NavigationOverlay: View {
    @EnvironmentObject var location: LocationManager
    @ObservedObject var nav: NavigationService
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @State private var searching: Bool = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !nav.searchResults.isEmpty {
                resultsList
            }
            Spacer()
            if nav.isNavigating {
                guidanceBar
            } else if nav.route != nil {
                routeSummary
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 60)
    }

    // ── Top bar: busca + fechar ──
    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.7))
            TextField("Endereço, lugar ou ponto…", text: $query)
                .focused($queryFocused)
                .submitLabel(.search)
                .foregroundStyle(.white).tint(.white)
                .onSubmit { Task { searching = true; await nav.search(query: query); searching = false } }
            if searching { ProgressView().tint(.white) }
            if !query.isEmpty {
                Button { query = ""; nav.searchResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
            }
            Button {
                if nav.isNavigating { nav.stopGuidance() }
                else { nav.route = nil; nav.steps = []; nav.searchResults = [] }
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.6), in: Circle())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .onAppear { nav.bind(location); queryFocused = true }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(nav.searchResults, id: \.self) { item in
                        Button {
                            queryFocused = false
                            Task {
                                await nav.calculateRoute(to: item)
                                nav.searchResults = []
                                query = item.name ?? ""
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2).foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "—").font(.body).foregroundStyle(.white)
                                    Text(addressLine(item.placemark))
                                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                                }
                                Spacer()
                            }.padding(12)
                        }
                        Divider().background(.white.opacity(0.1))
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.top, 8)
    }

    private var routeSummary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDistance(nav.route?.distance ?? 0))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text("Distância").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(nav.route?.expectedTravelTime ?? 0))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text("Tempo").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { nav.startGuidance() } label: {
                Label("Iniciar", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(.green, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    private var guidanceBar: some View {
        VStack(spacing: 8) {
            if nav.currentStepIndex < nav.steps.count {
                let step = nav.steps[nav.currentStepIndex]
                HStack(spacing: 14) {
                    Image(systemName: maneuverIcon(for: step.instructions))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white).frame(width: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatDistance(nav.distanceToNextStepM))
                            .font(.system(size: 28, weight: .heavy)).foregroundStyle(.cyan)
                        Text(step.instructions.isEmpty ? "Siga em frente" : step.instructions)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white).lineLimit(2)
                    }
                    Spacer()
                    Button { nav.stopGuidance() } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 44, height: 44)
                            .background(.red, in: Circle())
                            .foregroundStyle(.white)
                    }
                }
            }
            HStack(spacing: 12) {
                Label(formatTime(nav.etaSeconds), systemImage: "clock")
                Label(formatDistance(nav.remainingDistanceM), systemImage: "ruler")
                Spacer()
            }.font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private func addressLine(_ p: MKPlacemark) -> String {
        var parts: [String] = []
        if let s = p.thoroughfare { parts.append(s) }
        if let n = p.subThoroughfare { parts.append(n) }
        if let l = p.locality { parts.append(l) }
        if let u = p.administrativeArea { parts.append(u) }
        return parts.joined(separator: ", ")
    }
    private func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }
    private func formatTime(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)min" : "\(m) min"
    }
    private func maneuverIcon(for inst: String) -> String {
        let s = inst.lowercased()
        if s.contains("direita") || s.contains("right") { return "arrow.turn.up.right" }
        if s.contains("esquerda") || s.contains("left") { return "arrow.turn.up.left" }
        if s.contains("retorne") || s.contains("u-turn") { return "arrow.uturn.up" }
        if s.contains("saia") || s.contains("exit") { return "arrow.up.right" }
        if s.contains("rotatória") || s.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        if s.contains("chegou") || s.contains("destination") { return "flag.checkered" }
        return "arrow.up"
    }
}

// MARK: - MapKit UIKit bridge (mantém intacto, usado pelo ClusterMapView)

struct MapViewRepresentable: UIViewRepresentable {
    let route: MKRoute?
    let userLocation: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.userTrackingMode = .followWithHeading
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        if let r = route {
            map.addOverlay(r.polyline, level: .aboveRoads)
            let rect = r.polyline.boundingMapRect.insetBy(dx: -800, dy: -800)
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 100, left: 40, bottom: 240, right: 40), animated: true)
        } else if let loc = userLocation, map.region.span.latitudeDelta > 0.5 {
            // Só centraliza no usuário se ainda não foi posicionado (zoom inicial)
            let region = MKCoordinateRegion(center: loc,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            map.setRegion(region, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.cyan
                renderer.lineWidth = 6
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
