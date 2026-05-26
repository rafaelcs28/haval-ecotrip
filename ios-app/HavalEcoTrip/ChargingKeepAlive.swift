//
//  ChargingKeepAlive.swift
//  Mantém o app vivo em background via sessão de áudio silenciosa + polling,
//  permitindo que a Live Activity seja atualizada a cada ~30s sem depender do
//  BGTaskScheduler (intervalo controlado pelo iOS, ~15-30min).
//
//  O áudio é gerado programaticamente (sem arquivo), completamente inaudível e
//  usa .mixWithOthers — não interrompe música, podcasts nem chamadas.
//  Só roda enquanto o app está em background; para automaticamente ao voltar
//  pro foreground.
//
//  Modos (Settings.keepAliveMode):
//   .off           → desativado; BGTask normal (~15-30min)
//   .whileCharging → ativo somente enquanto há Live Activity de carga aberta
//   .always        → ativo sempre que o app vai pra background
//
import AVFoundation
import ActivityKit

final class ChargingKeepAlive {
    static let shared = ChargingKeepAlive()
    private init() {}

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var pollTimer: Timer?

    // ── Hooks chamados pelo ContentView ───────────────────────────────────────

    /// App foi para background. Passa se há Live Activity ativa no momento.
    func appDidBackground(hasActiveCharging: Bool) {
        switch Settings.keepAliveMode {
        case .off:          break
        case .whileCharging where hasActiveCharging: startBackground()
        case .whileCharging: break
        case .always:       startBackground()
        }
    }

    /// App voltou ao foreground — para áudio/timer (foreground polling assume).
    func appDidForeground() {
        stopBackground()
    }

    /// Live Activity de carga encerrada — para se estiver no modo whileCharging.
    func chargingDidStop() {
        if Settings.keepAliveMode == .whileCharging {
            stopBackground()
        }
    }

    // ── Engine de áudio silencioso ────────────────────────────────────────────

    private func startBackground() {
        guard engine == nil else { return }

        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // AVAudioSourceNode gerando zeros — silêncio sem arquivo de áudio.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, audioBufferList in
            let ptr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buf in ptr { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
            return noErr
        }
        let eng = AVAudioEngine()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: fmt)
        eng.mainMixerNode.outputVolume = 0
        try? eng.start()
        sourceNode = node
        engine    = eng

        // Polling a cada 30s para atualizar a Live Activity em background.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.pollAndUpdateLA() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        print("[keepalive] background ativo (modo: \(Settings.keepAliveMode.rawValue))")
    }

    private func stopBackground() {
        guard engine != nil || pollTimer != nil else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        engine?.stop()
        engine     = nil
        sourceNode = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[keepalive] background parado")
    }

    // ── Polling de estado ─────────────────────────────────────────────────────

    private func pollAndUpdateLA() async {
        let activities = await MainActor.run {
            Activity<ChargeActivityAttributes>.activities.filter { $0.activityState == .active }
        }
        guard let activity = activities.first else { return }
        guard let url = URL(string: Settings.bridgeURL + "/api/state") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
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
    }
}
