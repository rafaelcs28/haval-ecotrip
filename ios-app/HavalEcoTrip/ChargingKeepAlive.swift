//
//  ChargingKeepAlive.swift
//  Mantém o app vivo em background via sessão de áudio + polling a cada 30s,
//  permitindo atualizar a Live Activity sem depender de APNs ou BGTaskScheduler.
//
//  O áudio é gerado programaticamente (ruído sub-threshold, inaudível) com
//  .mixWithOthers para não interferir em músicas/podcasts.
//
//  Modos (Settings.keepAliveMode):
//   .off           → desativado
//   .whileCharging → ativo somente enquanto há Live Activity de carga aberta
//   .always        → ativo sempre que o app vai pra background
//
import AVFoundation
import ActivityKit

@MainActor
final class ChargingKeepAlive {
    static let shared = ChargingKeepAlive()
    private init() {
        // Observa interrupções de áudio (chamada, outro app) para reiniciar.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil)
    }

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var pollTimer: Timer?
    private var wantsBackground = false   // intenção — reinicia após interrupção

    // ── Hooks chamados pelo ContentView / ActivityManager ─────────────────────

    func appDidBackground(hasActiveCharging: Bool) {
        switch Settings.keepAliveMode {
        case .off:           break
        case .whileCharging: if hasActiveCharging { wantsBackground = true; startAudio() }
        case .always:        wantsBackground = true; startAudio()
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

    // ── Engine de áudio ───────────────────────────────────────────────────────

    private func startAudio() {
        // Não recria se já está rodando.
        if let eng = engine, eng.isRunning { return }

        // Para qualquer instância anterior sem limpar o timer.
        engine?.stop()
        engine = nil
        sourceNode = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[keepalive] AVAudioSession falhou: \(error) — sem keep-alive")
            return
        }

        // Ruído sub-threshold (< -80 dBFS): inaudível mas evita que o iOS
        // detecte silêncio puro e suspenda a sessão em background.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, audioBufferList in
            let ptr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buf in ptr {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(frameCount) {
                    data[i] = Float.random(in: -0.0001...0.0001)
                }
            }
            return noErr
        }
        let eng = AVAudioEngine()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: fmt)

        do {
            try eng.start()
        } catch {
            print("[keepalive] AVAudioEngine.start falhou: \(error) — sem keep-alive")
            return   // NÃO seta engine — permite retry na próxima interrupção
        }

        sourceNode = node
        engine = eng
        print("[keepalive] áudio iniciado (modo: \(Settings.keepAliveMode.rawValue))")

        // Inicia timer só se ainda não existe.
        if pollTimer == nil { startTimer() }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollAndUpdateLA() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopBackground() {
        pollTimer?.invalidate()
        pollTimer = nil
        engine?.stop()
        engine = nil
        sourceNode = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
        print("[keepalive] background parado")
    }

    // ── Recuperação de interrupção (chamada, Siri, outro app de áudio) ────────

    @objc private nonisolated func handleAudioInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }

        Task { @MainActor in
            switch type {
            case .began:
                // Interrupção iniciou — engine parou, mas mantemos wantsBackground.
                self.engine?.stop()
                self.engine = nil
                self.sourceNode = nil
                print("[keepalive] áudio interrompido")

            case .ended:
                guard self.wantsBackground else { return }
                // Reinicia áudio após fim da interrupção (ex: fim de chamada).
                let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    self.startAudio()
                    print("[keepalive] áudio reiniciado após interrupção")
                }

            @unknown default: break
            }
        }
    }

    // ── Polling de estado ─────────────────────────────────────────────────────

    private func pollAndUpdateLA() async {
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
            print("[keepalive] fetch falhou — próxima tentativa em 30s")
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
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
        print("[keepalive] LA atualizada — SOC \(Int(soc))%")
    }
}
