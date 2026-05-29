import Foundation
import MapKit
import CoreLocation
import AVFoundation
import Combine

/// Lógica de navegação turn-by-turn usando MapKit nativo.
///
/// Fluxo:
///   1. `search(query:)`  → MKLocalSearch retorna lista de destinos
///   2. `calculateRoute(to:)` → MKDirections traça rota com steps
///   3. `startGuidance()` → monitora GPS, identifica próximo step, fala em voz
///
/// Limitações da versão inicial:
///   - Sem recálculo automático se desviar (futuro)
///   - Voz em PT-BR via AVSpeechSynthesizer (Siri voice)
@MainActor
final class NavigationService: NSObject, ObservableObject {
    @Published var searchResults: [MKMapItem] = []
    @Published var route: MKRoute?
    @Published var steps: [MKRoute.Step] = []
    @Published var currentStepIndex: Int = 0
    @Published var distanceToNextStepM: Double = 0
    @Published var etaSeconds: TimeInterval = 0
    @Published var remainingDistanceM: Double = 0
    @Published var isNavigating: Bool = false
    @Published var lastError: String?

    private let speech = AVSpeechSynthesizer()
    private var locationUpdates: AnyCancellable?
    private weak var location: LocationManager?
    private var lastSpokenStepIndex: Int = -1

    func bind(_ location: LocationManager) {
        self.location = location
    }

    // ── Busca de endereço (MKLocalSearch) ────────────────────────────────
    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let loc = location, let la = loc.lat, let lo = loc.lng {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: la, longitude: lo),
                span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            self.searchResults = response.mapItems
            self.lastError = nil
        } catch {
            self.searchResults = []
            self.lastError = "Busca falhou: \(error.localizedDescription)"
        }
    }

    // ── Cálculo de rota (MKDirections) ────────────────────────────────────
    func calculateRoute(to destination: MKMapItem) async {
        guard let loc = location, let la = loc.lat, let lo = loc.lng else {
            lastError = "Sem GPS — aguarde a localização"
            return
        }
        let request = MKDirections.Request()
        let source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo)))
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let r = response.routes.first else {
                lastError = "Sem rota encontrada"
                return
            }
            self.route = r
            self.steps = r.steps
            self.currentStepIndex = 0
            self.etaSeconds = r.expectedTravelTime
            self.remainingDistanceM = r.distance
            self.lastError = nil
        } catch {
            self.lastError = "Erro de rota: \(error.localizedDescription)"
        }
    }

    // ── Guidance (monitora GPS, fala próximo turn) ────────────────────────
    func startGuidance() {
        guard route != nil, !steps.isEmpty else { return }
        isNavigating = true
        lastSpokenStepIndex = -1
        // Observa updates de GPS via LocationManager
        locationUpdates = location?.$lastFixAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tickGuidance() }
        // Fala primeira instrução
        speakCurrentStep()
    }

    func stopGuidance() {
        isNavigating = false
        locationUpdates?.cancel()
        locationUpdates = nil
        speech.stopSpeaking(at: .immediate)
        route = nil
        steps = []
        currentStepIndex = 0
    }

    private func tickGuidance() {
        guard isNavigating,
              let loc = location, let la = loc.lat, let lo = loc.lng,
              currentStepIndex < steps.count else { return }
        let here = CLLocation(latitude: la, longitude: lo)
        let step = steps[currentStepIndex]
        // Ponto final do step = endpoint da polyline
        let endCoord = step.polyline.coordinate
        let stepEnd = CLLocation(latitude: endCoord.latitude, longitude: endCoord.longitude)
        let dist = here.distance(from: stepEnd)
        distanceToNextStepM = dist

        // Atualiza distância restante total (aproximação: soma steps faltantes)
        var rem = dist
        for i in (currentStepIndex + 1)..<steps.count {
            rem += steps[i].distance
        }
        remainingDistanceM = rem
        if let r = route { etaSeconds = r.expectedTravelTime * (rem / max(r.distance, 1)) }

        // Avança step quando chega < 25m do endpoint
        if dist < 25 && currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
            speakCurrentStep()
        }
        // Aviso antecipado: a 250m do próximo turn, fala uma vez
        if dist < 250 && lastSpokenStepIndex != currentStepIndex {
            speakCurrentStep()
        }
    }

    private func speakCurrentStep() {
        guard currentStepIndex < steps.count else { return }
        let step = steps[currentStepIndex]
        let instruction = step.instructions
        guard !instruction.isEmpty else { return }
        lastSpokenStepIndex = currentStepIndex
        let utt = AVSpeechUtterance(string: instruction)
        utt.voice = AVSpeechSynthesisVoice(language: "pt-BR") ?? AVSpeechSynthesisVoice(language: "pt-PT")
        utt.rate = 0.5
        speech.speak(utt)
    }
}
