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
import UIKit

@MainActor
final class ChargingKeepAlive {
    static let shared = ChargingKeepAlive()
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil)
    }

    private var player: AVAudioPlayer?
    private var pollTimer: Timer?
    private var wantsBackground = false

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

    // ── AVAudioPlayer com tom 18kHz ───────────────────────────────────────────
    // AVAudioPlayer é mais confiável que AVAudioEngine para background keepalive.
    // 18kHz está acima da faixa audível para a maioria dos adultos; o iOS
    // reconhece como sinal real e mantém a sessão ativa.

    private func startAudio() {
        if let p = player, p.isPlaying { return }

        player?.stop()
        player = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[keepalive] AVAudioSession falhou: \(error)")
            return
        }

        do {
            let p = try AVAudioPlayer(data: makeToneWAV())
            p.numberOfLoops = -1   // loop infinito
            p.volume = 0.01        // quase inaudível mas não zero
            p.prepareToPlay()
            guard p.play() else {
                print("[keepalive] AVAudioPlayer.play() retornou false")
                return
            }
            player = p
            print("[keepalive] áudio iniciado (modo: \(Settings.keepAliveMode.rawValue))")
        } catch {
            print("[keepalive] AVAudioPlayer falhou: \(error)")
            return
        }

        if pollTimer == nil { startTimer() }
    }

    /// Gera 100ms de tom senoidal a 18kHz em formato WAV (16-bit, mono, 44100 Hz).
    private func makeToneWAV() -> Data {
        let sampleRate: Int   = 44100
        let frequency:  Float = 18000     // 18 kHz — acima da faixa audível humana
        let amplitude:  Float = 0.05      // ~-26 dBFS
        let numSamples        = sampleRate / 10   // 100ms
        let dataSize          = numSamples * 2    // 16-bit PCM

        var wav = Data(capacity: 44 + dataSize)
        func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }

        wav.append("RIFF".data(using: .ascii)!)
        wav.append(le32(UInt32(36 + dataSize)))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(le32(16))
        wav.append(le16(1))                          // PCM
        wav.append(le16(1))                          // mono
        wav.append(le32(UInt32(sampleRate)))
        wav.append(le32(UInt32(sampleRate * 2)))     // byte rate
        wav.append(le16(2))                          // block align
        wav.append(le16(16))                         // bits per sample
        wav.append("data".data(using: .ascii)!)
        wav.append(le32(UInt32(dataSize)))

        var phase: Float = 0
        let step = frequency / Float(sampleRate)
        for _ in 0..<numSamples {
            let sample = Int16(sin(2 * .pi * phase) * amplitude * Float(Int16.max))
            var s = sample.littleEndian
            wav.append(Data(bytes: &s, count: 2))
            phase += step
            if phase >= 1 { phase -= 1 }
        }
        return wav
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
        player?.stop()
        player = nil
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
        // Pede tempo extra ao iOS para garantir que o fetch complete.
        // beginBackgroundTask dá ~30s adicionais mesmo se o engine parar.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "keepalive-poll") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        // Verifica se o player ainda está tocando e reinicia se necessário.
        if let p = player, !p.isPlaying {
            print("[keepalive] player parou — reiniciando")
            startAudio()
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
