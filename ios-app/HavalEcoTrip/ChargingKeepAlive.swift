//
//  ChargingKeepAlive.swift
//  Mantém o app vivo em background via atualização de localização (CLLocationManager),
//  permitindo que a Live Activity seja atualizada a cada ~30s indefinidamente.
//
//  A localização é usada com a menor precisão possível (threeKilometers + cell/WiFi)
//  e distanceFilter = max para minimizar consumo de bateria. O app não armazena
//  nem usa os dados de localização — apenas mantém a sessão ativa.
//
//  O ícone de localização azul aparece na barra de status enquanto ativo.
//
//  Modos (Settings.keepAliveMode):
//   .off           → desativado
//   .whileCharging → ativo somente enquanto há Live Activity de carga aberta
//   .always        → ativo sempre que o app vai pra background
//
import CoreLocation
import ActivityKit
import UIKit

@MainActor
final class ChargingKeepAlive: NSObject {
    static let shared = ChargingKeepAlive()

    private var locationManager: CLLocationManager?
    private var pollTimer: Timer?
    private var wantsBackground = false

    private override init() { super.init() }

    // ── Hooks chamados pelo ContentView / ActivityManager ─────────────────────

    func appDidBackground(hasActiveCharging: Bool) {
        switch Settings.keepAliveMode {
        case .off:           break
        case .whileCharging: if hasActiveCharging { startBackground() }
        case .always:        startBackground()
        }
    }

    func appDidForeground() {
        wantsBackground = false
        stopBackground()
    }

    func chargingDidStop() {
        if Settings.keepAliveMode == .whileCharging {
            wantsBackground = false
            stopBackground()
        }
    }

    // ── CLLocationManager keep-alive ──────────────────────────────────────────

    /// Pede permissão de localização enquanto o app está em foreground.
    /// Deve ser chamado no onAppear/scenePhase=active se o modo não for .off.
    func requestPermissionIfNeeded() {
        guard Settings.keepAliveMode != .off else { return }
        let mgr = CLLocationManager()
        mgr.delegate = self
        locationManager = mgr
        if mgr.authorizationStatus == .notDetermined {
            mgr.requestAlwaysAuthorization()
        }
    }

    private func startBackground() {
        wantsBackground = true

        let mgr = CLLocationManager()
        mgr.delegate = self
        mgr.desiredAccuracy     = kCLLocationAccuracyThreeKilometers
        mgr.distanceFilter      = CLLocationDistanceMax   // ignora movimento
        mgr.pausesLocationUpdatesAutomatically = false
        mgr.allowsBackgroundLocationUpdates   = true
        locationManager = mgr

        switch mgr.authorizationStatus {
        case .notDetermined:
            mgr.requestAlwaysAuthorization()   // delegate inicia após resposta
        case .authorizedAlways, .authorizedWhenInUse:
            mgr.startUpdatingLocation()
            if pollTimer == nil { startTimer() }
            print("[keepalive] localização iniciada")
        default:
            print("[keepalive] sem permissão de localização — keep-alive inativo")
        }
    }

    private func stopBackground() {
        pollTimer?.invalidate()
        pollTimer = nil
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        print("[keepalive] background parado")
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollAndUpdateLA() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // ── Polling de estado ─────────────────────────────────────────────────────

    private func pollAndUpdateLA() async {
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "keepalive-poll") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }

        let activities = Activity<ChargeActivityAttributes>.activities.filter {
            $0.activityState == .active
        }
        guard let activity = activities.first else { return }
        guard let url = URL(string: Settings.bridgeURL + "/api/state") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[keepalive] fetch falhou")
            return
        }
        let charging = (json["charging_state"] as? String) == "Carregando"
        let soc = (json["soc_pct"]              as? Double) ?? 0
        let pwr = (json["charge_power_kw"]      as? Double) ?? 0
        let kwh = (json["charge_session_kwh"]   as? Double) ?? 0
        let rem = (json["charge_remaining_min"] as? Double) ?? 0
        let state = ChargeActivityAttributes.ContentState(
            soc: soc, powerKw: pwr, sessionKwh: kwh,
            remainingMin: Int(rem.rounded()),
            charging: charging,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )

        if !charging {
            // Recarga encerrada — encerra a Live Activity e para o keep-alive.
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.end(content, dismissalPolicy: .default)
            wantsBackground = false
            stopBackground()
            print("[keepalive] recarga encerrada — LA finalizada")
            return
        }

        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
        print("[keepalive] LA atualizada — SOC \(Int(soc))%")
    }
}

// ── CLLocationManagerDelegate ─────────────────────────────────────────────────

extension ChargingKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.wantsBackground else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
                if self.pollTimer == nil { self.startTimer() }
                print("[keepalive] permissão concedida — localização iniciada")
            default:
                print("[keepalive] permissão negada")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        // Localização não é usada — apenas mantém o processo vivo em background.
    }
}
