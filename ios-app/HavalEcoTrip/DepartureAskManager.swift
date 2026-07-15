//
//  DepartureAskManager.swift
//  Observa a transição desligado→ligado do carro (engineOn). Quando dispara,
//  consulta as Saídas monitoradas (bridge /api/departure-configs), checa se a
//  posição atual do carro está dentro do raio de alguma origem monitorada +
//  dentro da janela dia/hora + não em snooze + não perguntou hoje ainda. Se
//  passar tudo, cria a LA "Indo pra <dest>?" no lock screen.
//
//  LA é interativa (iOS 17+): botões Sim/Adiar/Não usam LiveActivityIntent que
//  hitam o bridge sem abrir o app.
//

import ActivityKit
import Combine
import CoreLocation
import Foundation

@available(iOS 17.0, *)
@MainActor
final class DepartureAskManager: ObservableObject {
    static let shared = DepartureAskManager()
    private init() {}

    private var bag: AnyCancellable?
    private var lastEngineOn = false
    private var lastCheckMs: Double = 0
    private let appGroup = "group.br.com.consorciolimpagyn.havalecotrip"

    /// Chamar no boot do app (em ContentView.onAppear ou App.init).
    func start() {
        // Snapshot inicial pra não disparar LA na primeira leitura.
        lastEngineOn = CarStore.shared.engineOn
        // Reage a cada mudança do CarStore. Só age em transição false→true.
        bag = CarStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in Task { await self?.tick() } }
    }

    private func tick() async {
        // Throttle: no máximo 1 check a cada 3s (o objectWillChange dispara bem).
        let now = Date().timeIntervalSince1970 * 1000
        if now - lastCheckMs < 3_000 { return }
        lastCheckMs = now
        let onNow = CarStore.shared.engineOn
        defer { lastEngineOn = onNow }
        guard !lastEngineOn && onNow else { return }   // só borda 0→1
        await evaluate()
    }

    private func evaluate() async {
        let configs = await CarIntentAPI.departureConfigs()
        guard !configs.isEmpty else { return }
        let car = CarStore.shared.coordinate
        // Sanity — carro sem GPS bom, ignora
        guard car.latitude != 0 || car.longitude != 0 else { return }
        let now = Date()
        let cal = Calendar.current
        let dow = cal.component(.weekday, from: now) - 1   // 0=Dom..6=Sáb
        let minuteOfDay = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let today = String(format: "%04d-%02d-%02d",
                           cal.component(.year, from: now), cal.component(.month, from: now), cal.component(.day, from: now))
        let ud = UserDefaults(suiteName: appGroup)
        for c in configs {
            guard (c["enabled"] as? Bool) != false else { continue }
            let cid = (c["config_id"] as? String) ?? ""
            guard !cid.isEmpty else { continue }
            let src = (c["source"] as? [String: Any]) ?? [:]
            let dst = (c["dest"] as? [String: Any]) ?? [:]
            guard let sLat = src["lat"] as? Double, let sLng = src["lng"] as? Double,
                  let sName = src["name"] as? String,
                  let dName = dst["name"] as? String else { continue }
            let sRadius = (src["radius_m"] as? Double) ?? 50
            // Janela + dias
            let days = (c["days"] as? [Int]) ?? []
            if !days.isEmpty && !days.contains(dow) { continue }
            let from = (c["from_hhmm"] as? Int) ?? 0
            let until = (c["until_hhmm"] as? Int) ?? 1439
            if minuteOfDay < from || minuteOfDay > until { continue }
            // Distância → origem
            let d = haversine(car.latitude, car.longitude, sLat, sLng)
            if d > max(sRadius, 30) { continue }
            // Já perguntou hoje?
            let askedKey = "departure_asked_\(cid)_\(today)"
            if ud?.bool(forKey: askedKey) == true { continue }
            // Em snooze?
            let snoozeUntil = ud?.double(forKey: "departure_snooze_\(cid)") ?? 0
            if snoozeUntil > now.timeIntervalSince1970 { continue }
            // Já tem LA ativa dessa config? evita duplicar.
            if Activity<DepartureAskActivityAttributes>.activities.contains(where: { $0.attributes.configId == cid }) { continue }
            // Marca "asked hoje" ANTES de disparar — evita rebounce se objectWillChange volta rápido.
            ud?.set(true, forKey: askedKey)
            let subject = (c["subject"] as? String) ?? "Grasi"
            startLA(configId: cid, sourceName: sName, destName: dName, subject: subject)
        }
    }

    private func startLA(configId: String, sourceName: String, destName: String, subject: String) {
        let attrs = DepartureAskActivityAttributes(configId: configId, sourceName: sourceName, destName: destName, subject: subject)
        let cs = DepartureAskActivityAttributes.ContentState(
            startedMs: Date().timeIntervalSince1970 * 1000, status: "asking", resultText: nil
        )
        do {
            _ = try Activity.request(
                attributes: attrs,
                content: ActivityContent(state: cs, staleDate: Date().addingTimeInterval(15 * 60)),
                pushType: nil   // não precisa APNs — atualização é local via intents
            )
        } catch {
            NSLog("[DepartureAskManager] falha ao iniciar LA: %@", error.localizedDescription)
        }
    }

    private func haversine(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (la2 - la1) * .pi / 180
        let dLon = (lo2 - lo1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(la1 * .pi / 180) * cos(la2 * .pi / 180) * sin(dLon/2) * sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
