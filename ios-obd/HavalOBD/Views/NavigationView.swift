import SwiftUI
import MapKit

/// Modal fullscreen de navegação turn-by-turn nativa Apple Maps.
///
/// Apresentado pelo botão Navegar do cluster. Substitui temporariamente
/// o WebView pelo MapKit nativo + busca + lista de manobras + voz.
struct NavigationModalView: View {
    @EnvironmentObject var location: LocationManager
    @StateObject private var nav = NavigationService()
    @Environment(\.dismiss) var dismiss
    @State private var query: String = ""
    @State private var searching: Bool = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        ZStack {
            MapViewRepresentable(route: nav.route, userLocation: userCLL)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)

            VStack(spacing: 0) {
                // ── Topo: busca + close ──
                topBar
                Spacer()
                // ── Bottom: status de navegação OU resultados de busca ──
                if nav.isNavigating {
                    guidanceBar
                } else if !nav.searchResults.isEmpty {
                    resultsList
                } else if nav.route != nil {
                    routeSummary
                }
            }
        }
        .onAppear { nav.bind(location) }
        .onDisappear { nav.stopGuidance() }
    }

    private var userCLL: CLLocationCoordinate2D? {
        guard let la = location.lat, let lo = location.lng else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }

    // ── Top bar: campo de busca + fechar ──
    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("Endereço, lugar ou ponto…", text: $query)
                .focused($queryFocused)
                .submitLabel(.search)
                .foregroundStyle(.white)
                .tint(.white)
                .onSubmit { Task { searching = true; await nav.search(query: query); searching = false } }
            if searching { ProgressView().tint(.white) }
            if !query.isEmpty {
                Button { query = ""; nav.searchResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
            }
            Button { dismiss() } label: {
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
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // ── Lista de resultados da busca ──
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
                                    Text(item.name ?? "—")
                                        .font(.body).foregroundStyle(.white)
                                    Text(addressLine(item.placemark))
                                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(12)
                        }
                        Divider().background(.white.opacity(0.1))
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // ── Resumo de rota antes de iniciar ──
    private var routeSummary: some View {
        VStack(spacing: 10) {
            if let err = nav.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
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
                Button {
                    nav.startGuidance()
                } label: {
                    Label("Iniciar", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // ── Barra de guidance ao vivo (próxima manobra) ──
    private var guidanceBar: some View {
        VStack(spacing: 8) {
            if nav.currentStepIndex < nav.steps.count {
                let step = nav.steps[nav.currentStepIndex]
                HStack(spacing: 14) {
                    Image(systemName: maneuverIcon(for: step.instructions))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatDistance(nav.distanceToNextStepM))
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(.cyan)
                        Text(step.instructions.isEmpty ? "Siga em frente" : step.instructions)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        nav.stopGuidance()
                    } label: {
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
            }
            .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // ── Helpers ──
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

// MARK: - MapKit UIKit bridge

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
        // Limpa overlays antigos
        map.removeOverlays(map.overlays)
        if let r = route {
            map.addOverlay(r.polyline, level: .aboveRoads)
            // Ajusta câmera pra mostrar rota inteira
            let rect = r.polyline.boundingMapRect.insetBy(dx: -800, dy: -800)
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 100, left: 40, bottom: 240, right: 40), animated: true)
        } else if let loc = userLocation {
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
