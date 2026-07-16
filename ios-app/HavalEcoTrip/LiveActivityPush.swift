//
//  LiveActivityPush.swift
//  Registra no bridge os tokens APNs das Live Activities (conta paga):
//   - push-to-start token (por TIPO): permite o SERVIDOR criar a LA com o app
//     fechado/bloqueado (iOS 17.2+).
//   - update token (por atividade): permite o servidor atualizar/encerrar a LA.
//
//  Substitui o antigo keep-alive de localização/áudio — agora quem dirige as
//  Live Activities é o bridge via APNs.
//
import Foundation
import ActivityKit

@MainActor
final class LiveActivityPush {
    static let shared = LiveActivityPush()
    private init() {}
    private var started = false
    // Cache dos push-to-start tokens (tipo → hex). O iOS emite o token uma vez
    // (às vezes ANTES do login); guardamos e re-registramos quando logar/abrir.
    private var ptsCache: [String: String] = [:]

    /// Reenvia os push-to-start tokens cacheados (chamar após login e ao abrir o app).
    func reregisterAll() {
        guard Settings.isConfigured, !ptsCache.isEmpty else { return }
        let snapshot = ptsCache
        Task {
            for (type, tok) in snapshot {
                await register("/api/activity/pts-token", body: [
                    "type": type, "push_to_start_token": tok, "device_id": Settings.notifDeviceId,
                ])
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        observe(ChargeActivityAttributes.self,   type: "ChargeActivityAttributes")
        observe(PreClimatActivityAttributes.self, type: "PreClimatActivityAttributes")
        observe(TripActivityAttributes.self,      type: "TripActivityAttributes")
        observe(MotorActivityAttributes.self,     type: "MotorActivityAttributes")
        observe(SecurityActivityAttributes.self,  type: "SecurityActivityAttributes")
        observe(InfraActivityAttributes.self,     type: "InfraActivityAttributes")
        observe(ParkingActivityAttributes.self,   type: "ParkingActivityAttributes")
        if #available(iOS 17.0, *) {
            observe(DepartureAskActivityAttributes.self, type: "DepartureAskActivityAttributes")
            // "Prime" o tipo novo pra iOS emitir pushToStartTokenUpdates. Sem
            // uma Activity criada UMA VEZ, iOS pode não inicializar a plumbing
            // do push-to-start pro tipo (padrão observado com tipos adicionados
            // depois da 1a instalação). Criamos uma efêmera e encerramos em 2s
            // — usuário não vê nada, mas o token nasce.
            Task { @MainActor in
                let existing = Activity<DepartureAskActivityAttributes>.activities
                let hasCached = ptsCache["DepartureAskActivityAttributes"] != nil
                if existing.isEmpty && !hasCached {
                    do {
                        let attrs = DepartureAskActivityAttributes(configId: "_prime", sourceName: "", destName: "", subject: "")
                        let cs = DepartureAskActivityAttributes.ContentState(startedMs: Date().timeIntervalSince1970 * 1000, status: "asking", resultText: nil)
                        let a = try Activity.request(
                            attributes: attrs,
                            content: ActivityContent(state: cs, staleDate: Date().addingTimeInterval(30)),
                            pushType: .token)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await a.end(nil, dismissalPolicy: .immediate)
                    } catch { /* silencioso — iOS emite token nas subs seguintes */ }
                }
            }
        }
        // A LA de recarga do BYD (SongPro) vive no app dedicado "Grasi Recarga"
        // (target BydRecarga), não mais aqui — fica separado do app do Haval.
    }

    private func observe<T: ActivityAttributes>(_ attr: T.Type, type: String) {
        // Push-to-start token (iOS 17.2+).
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<T>.pushToStartTokenUpdates {
                    let tok = hex(tokenData)
                    self.ptsCache[type] = tok   // cacheia mesmo se ainda não logado
                    await register("/api/activity/pts-token", body: [
                        "type": type,
                        "push_to_start_token": tok,
                        "device_id": Settings.notifDeviceId,
                    ])
                }
            }
        }
        // Atividades já ativas + futuras (inclui as criadas por push-to-start).
        let existing = Activity<T>.activities
        for activity in existing { track(activity, type: type) }
        // Só pode haver UMA LA ativa por tipo. Se sobraram duplicatas (ex.: restart
        // do bridge no meio da viagem criou outra), encerra as extras agora.
        if let keep = existing.last, existing.count > 1 { dedupe(type: T.self, keeping: keep.id) }
        Task {
            for await activity in Activity<T>.activityUpdates {
                track(activity, type: type)
                dedupe(type: T.self, keeping: activity.id)   // mantém a mais nova, encerra as outras
            }
        }
    }

    // Encerra todas as Live Activities ativas do tipo, exceto a `keepID`.
    private func dedupe<T: ActivityAttributes>(type: T.Type, keeping keepID: String) {
        for a in Activity<T>.activities where a.id != keepID && a.activityState == .active {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func track<T: ActivityAttributes>(_ activity: Activity<T>, type: String) {
        let id = activity.id
        // LA de "veículo desprotegido": criada por push-to-start, o bridge não
        // consegue encerrá-la por push enquanto o app está fechado (sem update token).
        // Ao detectá-la, consulta o estado e encerra LOCALMENTE se já está tudo seguro
        // — evita a LA ficar "presa" mostrando portas/trava que já normalizaram.
        if type == "SecurityActivityAttributes" {
            Task { await endSecurityIfSafe(activity) }
        }
        // LA de viagem: quando criada/mantida por push-to-start com o app morto, o
        // bridge nunca recebe o update token (pushTokenUpdates só emite com o app
        // vivo) → não consegue empurrar o fim, e a LA fica presa "em curso". Ao
        // detectá-la, consulta o bridge e encerra LOCALMENTE se não há viagem ativa.
        if type == "TripActivityAttributes" {
            Task { await endTripIfInactive(activity) }
        }
        Task {
            for await tokenData in activity.pushTokenUpdates {
                await register("/api/activity/start", body: [
                    "type": type, "activity_id": id,
                    "push_token": hex(tokenData),
                    "device_id": Settings.notifDeviceId,
                ])
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    await register("/api/activity/stop", body: ["activity_id": id])
                }
            }
        }
    }

    // Encerra a LA de segurança localmente se o bridge disser que não há mais nada
    // aberto/destrancado (issues vazio). Cobre o caso da LA presa por push-to-start.
    private func endSecurityIfSafe<T: ActivityAttributes>(_ activity: Activity<T>) async {
        guard Settings.isConfigured, let url = URL(string: Settings.apiBase + "/api/security/status") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issues = obj["issues"] as? [Any] else { return }
        if issues.isEmpty {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // Encerra a LA de viagem localmente se o bridge disser que não há viagem em
    // curso (current_trip null). Cobre a LA presa por push-to-start sem update token.
    private func endTripIfInactive<T: ActivityAttributes>(_ activity: Activity<T>) async {
        guard Settings.isConfigured, let url = URL(string: Settings.apiBase + "/api/state") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let st = (obj["state"] as? [String: Any]) ?? obj
        let hasTrip = st["current_trip"] != nil && !(st["current_trip"] is NSNull)
        if !hasTrip {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func register(_ pathSuffix: String, body: [String: Any]) async {
        guard Settings.isConfigured, let url = URL(string: Settings.apiBase + pathSuffix) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
