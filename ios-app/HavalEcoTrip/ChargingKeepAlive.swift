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
final class ChargingKeepAlive: NSObject, ObservableObject {
    static let shared = ChargingKeepAlive()

    /// Status atual de autorização — observável pela UI (botão nas Settings).
    @Published private(set) var authStatus: CLAuthorizationStatus = .notDetermined

    /// Manager persistente só para monitorar/pedir autorização. Precisa viver
    /// o app inteiro para o delegate receber a resposta dos prompts.
    private let authManager = CLLocationManager()
    private var locationManager: CLLocationManager?
    private var pollTimer: Timer?
    private var wantsBackground = false

    /// iOS só mostra o prompt "Sempre" uma vez por chamada direta. Depois disso,
    /// o usuário precisa ir aos Ajustes. Guardamos se já pedimos.
    private let alwaysAskedKey = "always_upgrade_asked"

    private override init() {
        super.init()
        authManager.delegate = self
        authStatus = authManager.authorizationStatus
    }

    // ── Hooks chamados pelo ContentView / ActivityManager ─────────────────────

    func appDidBackground(hasActiveCharging: Bool) {
        // Se há Live Activity de pré-climatização ativa, mantém o app vivo pra
        // continuar atualizando-a em background (best-effort), independente do modo.
        let preclimatActive = !Activity<PreClimatActivityAttributes>.activities
            .filter { $0.activityState == .active }.isEmpty
        if preclimatActive { startBackground(); return }

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
    ///
    /// IMPORTANTE: desde o iOS 13, o primeiro prompt NUNCA mostra "Sempre" —
    /// só "Ao Usar". Por isso pedimos WhenInUse aqui; a escalada para "Sempre"
    /// é feita explicitamente em `requestAlwaysUpgrade()` (botão nas Settings).
    func requestPermissionIfNeeded() {
        guard Settings.keepAliveMode != .off else { return }
        authStatus = authManager.authorizationStatus
        if authManager.authorizationStatus == .notDetermined {
            authManager.requestWhenInUseAuthorization()
        }
    }

    /// Escalada explícita para "Sempre", disparada por um botão consciente.
    /// O iOS só exibe o prompt "Mudar para Sempre" quando já existe "Ao Usar".
    func requestAlwaysUpgrade() {
        switch authManager.authorizationStatus {
        case .notDetermined:
            authManager.requestWhenInUseAuthorization()      // 1º passo
        case .authorizedWhenInUse:
            if UserDefaults.standard.bool(forKey: alwaysAskedKey) {
                openAppSettings()                            // iOS não reexibe o prompt
            } else {
                UserDefaults.standard.set(true, forKey: alwaysAskedKey)
                authManager.requestAlwaysAuthorization()     // 2º passo → prompt "Sempre"
            }
        case .denied, .restricted:
            openAppSettings()
        case .authorizedAlways:
            break                                            // já concedido
        @unknown default:
            break
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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

        // Best-effort: atualiza também a Live Activity da pré-climatização
        // enquanto o keep-alive estiver vivo em background.
        await PreClimatManager.shared.tick()

        let activities = Activity<ChargeActivityAttributes>.activities.filter {
            $0.activityState == .active
        }
        guard let activity = activities.first else {
            // Sem LA de carga. Se também não há LA de pré-climatização ativa e o
            // modo não é "sempre", solta o keep-alive — evita gastar bateria com
            // localização em background depois que a pré-climatização encerra.
            let preclimatActive = !Activity<PreClimatActivityAttributes>.activities
                .filter { $0.activityState == .active }.isEmpty
            if !preclimatActive && Settings.keepAliveMode != .always {
                stopBackground()
            }
            return
        }
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
            self.authStatus = manager.authorizationStatus
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
