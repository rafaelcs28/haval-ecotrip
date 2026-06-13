//
//  CalendarPreclimat.swift
//  Pré-clima por agenda — lê os próximos compromissos do Calendário (EventKit) e
//  agenda um pré-clima único no bridge (schedule once + onceAtMs) calculando a hora
//  de saída. Quando o evento tem local, usa /api/route-plan pra estimar o tempo de
//  viagem e checar se a autonomia (range EV/total) chega no destino.
//
//  O DISPARO acontece no bridge (sempre online), não no app — o iOS só sincroniza o
//  próximo compromisso ao abrir/atualizar. Sem dependência de background confiável.
//

import SwiftUI
import EventKit
import CoreLocation

enum RangeVerdict { case ev, total, insufficient, unknown }

struct UpcomingEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let lat: Double?
    let lng: Double?
    let locationText: String?

    var hasDestination: Bool { lat != nil || (locationText?.isEmpty == false) }
}

@MainActor
final class CalendarPreclimatStore: ObservableObject {
    static let shared = CalendarPreclimatStore()

    @AppStorage("cal_preclimat_enabled") var enabled = false
    @AppStorage("cal_preclimat_sched_id") private var schedId = ""

    @Published var authorized = false
    @Published var nextEvent: UpcomingEvent?
    @Published var departure: Date?          // hora estimada de sair de casa
    @Published var fireAt: Date?             // quando o pré-clima liga (= onceAtMs)
    @Published var verdict: RangeVerdict = .unknown
    @Published var distanceKm: Double?
    @Published var busy = false

    private let store = EKEventStore()
    private let climateDurationMin = 20      // tempo de pré-climatização
    private let leaveBufferMin = 3           // folga antes da viagem

    // ── Acesso ao calendário ────────────────────────────────────────────────
    func refreshAuth() {
        let st = EKEventStore.authorizationStatus(for: .event)
        authorized = (st == .fullAccess || st == .authorized)
    }

    func requestAccess() async {
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        authorized = ok
        if ok { await sync() }
    }

    // ── Leitura dos compromissos ──────────────────────────────────────────────
    private func upcoming() -> UpcomingEvent? {
        let now = Date()
        let end = now.addingTimeInterval(24 * 3600)
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let evs = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(60) }
            .sorted { $0.startDate < $1.startDate }
        guard let e = evs.first else { return nil }
        let geo = e.structuredLocation?.geoLocation?.coordinate
        return UpcomingEvent(
            id: e.eventIdentifier ?? UUID().uuidString,
            title: e.title ?? "Compromisso",
            start: e.startDate,
            lat: geo?.latitude, lng: geo?.longitude,
            locationText: e.location)
    }

    // ── Sincronização (chamada ao abrir o app / refresh) ──────────────────────
    func sync() async {
        refreshAuth()
        guard authorized else { return }
        guard enabled else { await clearSchedule(); reset(); return }
        busy = true
        defer { busy = false }

        guard let ev = upcoming() else { reset(); await clearSchedule(); return }
        nextEvent = ev

        // Tempo de viagem + autonomia (só se o evento tem destino e o carro tem GPS).
        var travelMin = 0
        verdict = .unknown; distanceKm = nil
        let car = CarStore.shared
        if ev.hasDestination, car.lat != 0 || car.lng != 0 {
            if let plan = await routePlan(from: (car.lat, car.lng), ev: ev) {
                travelMin = plan.durationMin
                distanceKm = plan.distanceKm
                let evRange = car.rangeEvKm
                let total = evRange + car.rangeIceKm
                verdict = plan.distanceKm <= evRange ? .ev
                        : plan.distanceKm <= total ? .total : .insufficient
            }
        }

        // Hora de sair: início do evento − viagem − folga. Pré-clima liga em
        // (saída − duração da climatização) pra cabine ficar pronta na saída.
        let dep = ev.start.addingTimeInterval(-Double(travelMin + leaveBufferMin) * 60)
        let fire = dep.addingTimeInterval(-Double(climateDurationMin) * 60)
        departure = dep; fireAt = fire

        // Já passou da hora de ligar → não agenda (tarde demais).
        guard fire > Date() else { await clearSchedule(); return }
        await pushSchedule(fireAt: fire, temp: suggestedTemp())
    }

    private func suggestedTemp() -> Double {
        let t = CarStore.shared.outsideTemp
        if t >= 27 { return 22 }            // esfriar
        if t > 0 && t <= 15 { return 23 }   // aquecer
        return 22
    }

    private func reset() {
        nextEvent = nil; departure = nil; fireAt = nil
        verdict = .unknown; distanceKm = nil
    }

    // ── Bridge ────────────────────────────────────────────────────────────────
    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func req(_ path: String, _ method: String, _ body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let body {
            r.addValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func routePlan(from: (Double, Double), ev: UpcomingEvent) async -> (distanceKm: Double, durationMin: Int)? {
        var q = "from_lat=\(from.0)&from_lng=\(from.1)"
        if let la = ev.lat, let lo = ev.lng { q += "&to_lat=\(la)&to_lng=\(lo)" }
        else if let loc = ev.locationText, !loc.isEmpty {
            q += "&q=\(loc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        } else { return nil }
        guard let r = req("/api/route-plan?\(q)", "GET"),
              let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let km = (obj["distanceKm"] as? NSNumber)?.doubleValue
        let min = (obj["durationMin"] as? NSNumber)?.intValue
        guard let km, let min else { return nil }
        return (km, min)
    }

    private func pushSchedule(fireAt: Date, temp: Double) async {
        let ms = Int(fireAt.timeIntervalSince1970 * 1000)
        let hhmm = DateFormatter.hhmm.string(from: fireAt)
        var body: [String: Any] = [
            "device_id": "calendar",
            "onceAtMs": ms, "time": hhmm, "temp": temp,
            "duration": climateDurationMin, "enabled": true,
        ]
        if !schedId.isEmpty { body["id"] = schedId }
        guard let r = req("/api/preclimat/schedule", "POST", body),
              let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = obj["id"] as? String { schedId = id }
    }

    private func clearSchedule() async {
        guard !schedId.isEmpty else { return }
        if let r = req("/api/preclimat/schedule/\(schedId)", "DELETE") {
            _ = try? await URLSession.shared.data(for: r)
        }
        schedId = ""
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        Task { await sync() }
    }
}

private extension DateFormatter {
    static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
