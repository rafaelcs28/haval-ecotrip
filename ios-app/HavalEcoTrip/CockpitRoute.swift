//  CockpitRoute.swift
//  Cockpit da aba Drive: rota + próxima manobra + map-matching + voz.
//  Fonte preferida = bridge (Mapbox driving-traffic): geometria com trânsito ao vivo,
//  manobras com nome de via e limite de velocidade. Fallback (mock/preview) = MKDirections.
//  O carro é "snapado" na polyline (resolve lado da avenida) e o heading vem da tangente.

import SwiftUI
import MapKit
import CoreLocation
import AVFoundation

extension MKPolyline {
    var coords: [CLLocationCoordinate2D] {
        var arr = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&arr, range: NSRange(location: 0, length: pointCount))
        return arr
    }
}

struct BridgeManeuver {
    let coord: CLLocationCoordinate2D
    let text: String
    let type: String
    let modifier: String
}

struct Maneuver: Equatable {
    let id: Int            // vértice-âncora na rota (estável enquanto for a mesma manobra)
    let instruction: String
    let icon: String
    let distanceM: Double
    let progress: Double   // 0 = acabou de virar a anterior, 1 = na manobra
}

@MainActor
final class CockpitRouteStore: ObservableObject {
    @Published var coords: [CLLocationCoordinate2D] = []
    @Published var maneuver: Maneuver?
    @Published var matchedCar: CLLocationCoordinate2D?   // carro snapado na rota
    @Published var courseHeading: Double?                // rumo pela tangente da rota
    @Published var speedLimit: Int?                      // limite de velocidade da via (km/h)

    var voiceEnabled = false

    private enum Src { case none, bridge, apple }
    private var source: Src = .none
    private var turns: [(idx: Int, instr: String, icon: String)] = []

    // throttle do fallback Apple
    private var lastDest: CLLocationCoordinate2D?
    private var lastComputeAt = Date.distantPast
    private var computing = false

    // voz
    private let synth = AVSpeechSynthesizer()
    private var spokenAnchor = -1
    private var spokenThresholds: Set<Int> = []

    func clear() {
        coords = []; maneuver = nil; matchedCar = nil; courseHeading = nil
        speedLimit = nil; turns = []; source = .none; lastDest = nil
        spokenAnchor = -1; spokenThresholds = []
    }

    // Preferido: rota do bridge (geometria + manobras com nome de via + limite).
    func setBridgeRoute(_ geo: [CLLocationCoordinate2D], maneuvers: [BridgeManeuver],
                        speedLimit sl: Int?, car: CLLocationCoordinate2D) {
        guard geo.count > 1 else { clear(); return }
        source = .bridge
        speedLimit = sl
        if !sameGeometry(geo, coords) {
            coords = geo
            turns = maneuvers.isEmpty ? deriveTurns(geo) : turnsFromBridge(maneuvers, geo: geo)
        }
        matchAndRefresh(car: car)
    }

    // Fallback: rota Apple (só quando não há bridge — mock/preview).
    func updateApple(car: CLLocationCoordinate2D, dest: CLLocationCoordinate2D?) {
        guard let dest, CLLocationCoordinate2DIsValid(car), CLLocationCoordinate2DIsValid(dest) else { clear(); return }
        if source == .bridge { source = .apple; speedLimit = nil }
        let moved = lastDest.map { dist($0, dest) > 40 } ?? true
        let stale = Date().timeIntervalSince(lastComputeAt) > 25
        if !computing && (moved || stale || coords.isEmpty) { recomputeApple(car: car, dest: dest) }
        matchAndRefresh(car: car)
    }

    func onCar(_ car: CLLocationCoordinate2D) {
        guard !coords.isEmpty else { return }
        matchAndRefresh(car: car)
    }

    // MARK: - Apple MKDirections (fallback)

    private func recomputeApple(car: CLLocationCoordinate2D, dest: CLLocationCoordinate2D) {
        computing = true; lastDest = dest; lastComputeAt = Date()
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: car))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        req.transportType = .automobile
        Task { [weak self] in
            let route = try? await MKDirections(request: req).calculate()
            await MainActor.run {
                guard let self else { return }
                self.computing = false
                guard self.source != .bridge, let r = route?.routes.first else { return }
                let geo = r.polyline.coords.filter { CLLocationCoordinate2DIsValid($0) }
                guard geo.count > 1 else { return }
                self.coords = geo
                self.turns = self.deriveTurns(geo)
                self.matchAndRefresh(car: car)
            }
        }
    }

    // MARK: - map-matching + manobra

    private func matchAndRefresh(car: CLLocationCoordinate2D) {
        guard coords.count > 1 else { matchedCar = nil; courseHeading = nil; maneuver = nil; return }
        let s = snap(car)
        if s.dist > 90 { matchedCar = nil; courseHeading = nil } else {
            matchedCar = s.point
            courseHeading = bearing(coords[s.seg], coords[min(s.seg + 1, coords.count - 1)])
        }
        let m = nextManeuver(seg: s.seg, snap: matchedCar ?? car)
        maneuver = m
        if let m { speakIfNeeded(m) }
    }

    private func snap(_ p: CLLocationCoordinate2D) -> (point: CLLocationCoordinate2D, seg: Int, dist: Double) {
        var best = (point: coords[0], seg: 0, dist: Double.infinity)
        for i in 0..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let mLat = 111_320.0, mLng = 111_320.0 * cos(a.latitude * .pi / 180)
            let bx = (b.longitude - a.longitude) * mLng, by = (b.latitude - a.latitude) * mLat
            let px = (p.longitude - a.longitude) * mLng, py = (p.latitude - a.latitude) * mLat
            let len2 = bx * bx + by * by
            let t = len2 > 0 ? max(0, min(1, (px * bx + py * by) / len2)) : 0
            let cx = t * bx, cy = t * by
            let d = hypot(px - cx, py - cy)
            if d < best.dist {
                let pt = CLLocationCoordinate2D(latitude: a.latitude + cy / mLat,
                                                longitude: a.longitude + cx / mLng)
                best = (pt, i, d)
            }
        }
        return best
    }

    private func nextManeuver(seg: Int, snap: CLLocationCoordinate2D) -> Maneuver? {
        guard !turns.isEmpty else { return nil }
        let target = turns.first { $0.idx > seg } ?? turns[turns.count - 1]
        let prevIdx = turns.last { $0.idx <= seg }?.idx ?? 0
        let remaining = alongRoute(from: seg, snap: snap, toVertex: target.idx)
        let segTotal = alongVertices(prevIdx, target.idx)
        let progress = segTotal > 1 ? max(0, min(1, 1 - remaining / segTotal)) : 0
        return Maneuver(id: target.idx, instruction: target.instr, icon: target.icon,
                        distanceM: remaining, progress: progress)
    }

    // Distância ao longo da rota do ponto snapado (no segmento `seg`) até `toVertex`.
    private func alongRoute(from seg: Int, snap: CLLocationCoordinate2D, toVertex: Int) -> Double {
        guard toVertex > seg else { return 0 }
        var rem = dist(snap, coords[min(seg + 1, coords.count - 1)])
        var i = seg + 1
        while i < toVertex && i < coords.count - 1 { rem += dist(coords[i], coords[i + 1]); i += 1 }
        return rem
    }
    private func alongVertices(_ a: Int, _ b: Int) -> Double {
        guard b > a else { return 0 }
        var s = 0.0, i = a
        while i < b && i < coords.count - 1 { s += dist(coords[i], coords[i + 1]); i += 1 }
        return s
    }

    // MARK: - voz

    private func speakIfNeeded(_ m: Maneuver) {
        guard voiceEnabled else { return }
        if m.id != spokenAnchor { spokenAnchor = m.id; spokenThresholds = [] }
        let d = m.distanceM
        var phrase: String?
        if d <= 30, !spokenThresholds.contains(0) { spokenThresholds.insert(0); phrase = m.instruction }
        else if d <= 120, !spokenThresholds.contains(100) { spokenThresholds.insert(100); phrase = m.instruction }
        else if d <= 420, !spokenThresholds.contains(400) {
            spokenThresholds.insert(400); phrase = "Em \(Int((d / 100).rounded()) * 100) metros, \(m.instruction)"
        }
        guard let phrase else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: phrase)
        u.voice = AVSpeechSynthesisVoice(language: "pt-BR")
        u.rate = 0.5
        synth.speak(u)
    }

    // MARK: - manobras a partir do bridge (nome de via + ícone por type/modifier)

    private func turnsFromBridge(_ ms: [BridgeManeuver], geo: [CLLocationCoordinate2D]) -> [(idx: Int, instr: String, icon: String)] {
        var out: [(idx: Int, instr: String, icon: String)] = []
        for m in ms {
            if m.type == "depart" { continue }
            let idx = nearestIndex(m.coord, in: geo)
            let instr = m.text.isEmpty ? "Siga em frente" : m.text
            out.append((idx, instr, iconFor(type: m.type, modifier: m.modifier)))
        }
        out.sort { $0.idx < $1.idx }
        if out.last?.idx != geo.count - 1 { out.append((geo.count - 1, "Chegar ao destino", "flag.checkered")) }
        return out
    }

    private func iconFor(type: String, modifier: String) -> String {
        if type == "arrive" { return "flag.checkered" }
        if type.contains("roundabout") || type.contains("rotary") { return "arrow.triangle.turn.up.right.circle" }
        if type == "on ramp" || type == "off ramp" || type == "fork" { return "arrow.up.right" }
        switch modifier {
        case "uturn": return "arrow.uturn.down"
        case "sharp right", "right", "slight right": return "arrow.turn.up.right"
        case "sharp left", "left", "slight left": return "arrow.turn.up.left"
        default: return "arrow.up"
        }
    }

    private func nearestIndex(_ p: CLLocationCoordinate2D, in geo: [CLLocationCoordinate2D]) -> Int {
        var best = 0, bestD = Double.infinity
        for (i, c) in geo.enumerated() {
            let dx = c.longitude - p.longitude, dy = c.latitude - p.latitude, d = dx * dx + dy * dy
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: - fallback DIY (geometria pura)

    private func deriveTurns(_ g: [CLLocationCoordinate2D]) -> [(idx: Int, instr: String, icon: String)] {
        var out: [(idx: Int, instr: String, icon: String)] = []
        guard g.count >= 3 else {
            if g.count >= 1 { out = [(g.count - 1, "Chegar ao destino", "flag.checkered")] }
            return out
        }
        var i = 1
        while i < g.count - 1 {
            var j = i - 1; while j > 0 && dist(g[j], g[i]) < 25 { j -= 1 }
            var k = i + 1; while k < g.count - 1 && dist(g[i], g[k]) < 25 { k += 1 }
            var d = bearing(g[i], g[k]) - bearing(g[j], g[i])
            while d > 180 { d -= 360 }; while d < -180 { d += 360 }
            if abs(d) >= 30 {
                out.append((i, label(d).instr, label(d).icon))
                i = k
            } else { i += 1 }
        }
        out.append((g.count - 1, "Chegar ao destino", "flag.checkered"))
        return out
    }

    private func label(_ d: Double) -> (instr: String, icon: String) {
        if abs(d) >= 150 { return ("Retorno", "arrow.uturn.down") }
        if d > 0 { return ("Vire à direita", "arrow.turn.up.right") }
        return ("Vire à esquerda", "arrow.turn.up.left")
    }

    // MARK: - geometria

    private func sameGeometry(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
        guard a.count == b.count, let a0 = a.first, let b0 = b.first, let an = a.last, let bn = b.last else { return false }
        let e = 1e-6
        return abs(a0.latitude - b0.latitude) < e && abs(a0.longitude - b0.longitude) < e
            && abs(an.latitude - bn.latitude) < e && abs(an.longitude - bn.longitude) < e
    }

    private func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
