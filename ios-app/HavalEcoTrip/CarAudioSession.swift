//  CarAudioSession.swift
//  Escuta ao vivo da cabine: abre a sessão no carro (POST /api/audio/listen),
//  conecta no relay WS /ws/audio e toca o PCM que chega (carro→fone). Push-to-talk
//  captura o mic do iPhone e manda PCM pelo mesmo WS (fone→carro). Half-duplex.
//  Formato fixo: PCM16 LE mono 8kHz (casa com o APK e o bridge).

import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class CarAudioSession: ObservableObject {
    // Singleton p/ escuta ao vivo: sobrevive ao ciclo de vida da sheet — fechar
    // sheet, trocar de tela ou minimizar (background audio via UIBackgroundModes:
    // audio no project.yml) NÃO para o playback. Só para com ação explícita.
    // MicTestSheet segue criando instância própria (diag isolado por sessão).
    static let shared = CarAudioSession()

    enum State: Equatable { case idle, connecting, listening, error(String) }
    @Published var state: State = .idle
    @Published var talking = false
    @Published var level: Double = 0        // nível de entrada 0…1 (VU meter)
    @Published var reconnecting = false
    @Published var inCall = false           // chamada full-duplex ativa
    @Published var callStatus = ""          // "Chamando…", "Em chamada", "Encerrada"
    @Published var muted = false            // silencia só o playback local

    @Published private(set) var callMode = false

    private var reconnectAttempt = 0
    private var interruptionObserver: NSObjectProtocol?
    private let rate = 8000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private lazy var pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private var ws: URLSessionWebSocketTask?
    private var talkConverter: AVAudioConverter?
    private var tapInstalled = false
    private var micGranted = false

    private var base: String { BridgeRouter.shared.currentURL }

    func start() async {
        guard state == .idle else { return }
        state = .connecting
        // Mic do iPhone é só pro push-to-talk. Sem ele a escuta (playback) ainda
        // funciona — por isso não bloqueia, só decide a categoria/o tap.
        micGranted = await askMicPermission()
        guard await controlCar(action: "start") else { state = .error("Carro não respondeu."); return }
        do {
            try configureSession()
            try startEngine()
            connectWS()
            state = .listening
            configureNowPlaying(title: "Escuta da cabine")
            configureRemoteCommands()
            observeInterruptions()
        } catch {
            await controlCar(action: "stop")
            state = .error("Áudio: \(error.localizedDescription)")
        }
    }

    private func askMicPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    func stop() async {
        teardownAudio()
        await controlCar(action: "stop")
    }

    // Desmonta WS + engine + sessão SEM avisar o carro (controlCar). A chamada
    // reusa a escuta (liveActive=true no carro); se o endCall mandasse stop no
    // /api/audio/listen, o carro pararia a captura e derrubaria a chamada.
    private func teardownAudio() {
        state = .idle   // antes do cancel: impede o scheduleReconnect de reabrir
        reconnecting = false; level = 0; callMode = false
        muted = false; engine.mainMixerNode.outputVolume = 1
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        talking = false
        state = .idle
        clearNowPlaying()
    }

    // ── Now Playing / Lock-screen ────────────────────────────────────────────
    // Sem isso, iOS não mostra nada no Control Center/tela bloqueada durante o
    // playback em background e o usuário não consegue encerrar dali.
    private func configureNowPlaying(title: String) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "Haval EcoTrip"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let c = MPRemoteCommandCenter.shared()
        c.stopCommand.removeTarget(self)
        c.pauseCommand.removeTarget(self)
        c.playCommand.removeTarget(self)
        c.togglePlayPauseCommand.removeTarget(self)
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        // Encerra escuta / chamada pela tela bloqueada. pauseCommand duplica o
        // stop porque muitos widgets mostram Pause em vez de Stop.
        let end: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.callMode { await self.endCall() } else { await self.stop() }
            }
            return .success
        }
        c.stopCommand.isEnabled = true
        c.stopCommand.addTarget(handler: end)
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget(handler: end)
        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget(handler: end)
        // Live stream não retoma — desabilita play pra não confundir.
        c.playCommand.isEnabled = false
    }

    // ── Interrupções (ligação, Siri, alarme) ─────────────────────────────────
    // iOS pausa o AVAudioEngine sozinho no .began; no .ended, se `shouldResume`
    // vier ligado, reativa a sessão e o engine pra escuta longa sobreviver.
    // Registro idempotente por instância; observer é solto no deinit por segurança.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Nada a fazer — iOS já pausou o engine. Resume depende do .shouldResume no .ended.
            break
        case .ended:
            guard state == .listening else { return }
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            guard opts.contains(.shouldResume) else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                if !engine.isRunning { try engine.start() }
                player.play()
                configureNowPlaying(title: callMode ? "Chamada com o carro" : "Escuta da cabine")
            } catch {
                // Se o restart local falhar, força reconexão do WS (o carro segue capturando).
                scheduleReconnect()
            }
        @unknown default:
            break
        }
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func setMuted(_ on: Bool) {
        muted = on
        engine.mainMixerNode.outputVolume = on ? 0 : 1
    }

    func setTalking(_ on: Bool) {
        guard micGranted else { return }   // sem mic não há push-to-talk
        talking = on
        if on { ws?.send(.string("talk:on")) { _ in } }
    }

    // ── Carro: liga/desliga a captura via bridge ────────────────────────────
    @discardableResult private func controlCar(action: String) async -> Bool {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/audio/listen") else { return false }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action, "talk": true])
        if let (_, resp) = try? await URLSession.shared.data(for: r) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }

    // ── Áudio iOS ───────────────────────────────────────────────────────────
    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        if micGranted {
            // .default (NÃO .voiceChat): voiceChat roteia o áudio pelo volume de
            // ligação do iOS, que fica mudo sem chamada telefônica ativa do sistema —
            // causando silêncio total na escuta e na chamada. .default usa o volume
            // de mídia que sempre funciona. AEC full-duplex não é necessário aqui
            // porque o mic do carro fica longe das caixas.
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            // Sem mic: só toca o áudio do carro (escuta passiva). Evita o erro de
            // ativar playAndRecord sem permissão, que abortava a sessão inteira.
            try s.setCategory(.playback, mode: .default, options: [])
        }
        try s.setActive(true)
    }

    private func startEngine() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        engine.mainMixerNode.outputVolume = 1.0
        // Tap do mic pra push-to-talk (converte hw→8kHz PCM16 só quando talking).
        // Só com permissão — acessar o inputNode sem mic derruba o engine.
        if micGranted {
            let input = engine.inputNode
            let hwFmt = input.inputFormat(forBus: 0)
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
            talkConverter = AVAudioConverter(from: hwFmt, to: outFmt)
            input.installTap(onBus: 0, bufferSize: 1024, format: hwFmt) { [weak self] buf, _ in
                self?.onMicBuffer(buf, outFmt: outFmt)
            }
            tapInstalled = true
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func onMicBuffer(_ buf: AVAudioPCMBuffer, outFmt: AVAudioFormat) {
        guard talking, let conv = talkConverter, let ws = ws else { return }
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * 2
        let data = Data(bytes: ch[0], count: bytes)
        ws.send(.data(data)) { _ in }
    }

    // ── Relay WS ─────────────────────────────────────────────────────────────
    private func connectWS() {
        let scheme = base.hasPrefix("https") ? "wss" : "ws"
        let host = base.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let tok = Settings.bridgeToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let u = URL(string: "\(scheme)://\(host)/ws/audio?token=\(tok)") else { return }
        let task = URLSession.shared.webSocketTask(with: u)
        ws = task
        task.resume()
        receive()
    }

    private func receive() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .data(let d): Task { @MainActor in self.enqueue(d) }
                case .string(let s): Task { @MainActor in self.onSignal(s) }
                @unknown default: break
                }
                self.receive()
            case .failure:
                // Não erra direto: em rede móvel/background o WS cai sozinho. Tenta
                // reconectar com backoff enquanto a escuta estiver ligada.
                Task { @MainActor in if self.state == .listening { self.scheduleReconnect() } }
            }
        }
    }

    private func scheduleReconnect() {
        guard state == .listening, !reconnecting else { return }
        reconnecting = true
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 8.0)   // 1,2,4,8s (cap)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.state == .listening else { self.reconnecting = false; return }
            await self.controlCar(action: "start")   // reabre a captura no carro (idempotente)
            self.ws?.cancel(with: .goingAway, reason: nil)
            self.connectWS()
            self.reconnecting = false
        }
    }

    private func enqueue(_ data: Data) {
        let n = data.count / 2
        guard n > 0, engine.isRunning,
              let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        reconnectAttempt = 0   // chegou áudio → conexão saudável, zera o backoff
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            let i16 = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let s = Float(Int16(littleEndian: i16[i])) / 32768.0
                out[i] = s
                let a = abs(s); if a > peak { peak = a }
            }
        }
        // Meter com decaimento (pico sobe na hora, desce suave).
        level = max(Double(peak), level * 0.82)
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    // ── Chamada full-duplex (iOS → carro) ────────────────────────────────────
    // Eventos do ciclo de vida chegam como texto pelo mesmo WS: o carro publica
    // em call/event → bridge → "call:<state>" pra todos os audioClients.
    private func onSignal(_ s: String) {
        guard s.hasPrefix("call:") else { return }
        switch String(s.dropFirst(5)) {
        case "ringing":  callStatus = "Tocando no carro…"
        case "accepted": callStatus = "Em chamada"; inCall = true
        case "busy":     callStatus = "Carro ocupado"; finishCall()
        case "ended":    callStatus = "Encerrada"; finishCall()
        default: break
        }
    }

    // Liga pro carro: abre a sessão de escuta (carro→fone) e, ao mesmo tempo,
    // mantém o mic do iPhone aberto contínuo (fone→carro) = full-duplex.
    func startCall(message: String) async {
        guard state == .idle, !inCall else { return }
        callMode = true
        callStatus = "Chamando…"
        state = .connecting
        micGranted = await askMicPermission()
        guard micGranted else { state = .idle; callMode = false; callStatus = "Sem permissão de microfone"; return }
        // Só dispara o ring; a captura do carro abre no accept (CallManager →
        // CarAudioRelay.startCall). Não chamamos controlCar aqui pra não vazar a
        // cabine antes do motorista aceitar.
        guard await requestCall(message: message) else {
            state = .idle; callMode = false; callStatus = "Carro não respondeu."
            return
        }
        do {
            try configureSession()
            try startEngine()
            connectWS()
            state = .listening
            talking = true   // mic contínuo: full-duplex (sem push-to-talk)
            configureNowPlaying(title: "Chamada com o carro")
            configureRemoteCommands()
            observeInterruptions()
        } catch {
            await controlCar(action: "stop")
            state = .idle; callMode = false; callStatus = "Áudio: \(error.localizedDescription)"
        }
    }

    func endCall() async {
        guard callMode else { return }
        await requestCallEnd()
        finishCall()
    }

    private func finishCall() {
        inCall = false
        teardownAudio()
    }

    // POST /api/call/start {message} → carro toca a tela e auto-aceita em 10s.
    private func requestCall(message: String) async -> Bool {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/call/start") else { return false }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["caller": "iPhone", "message": message])
        if let (_, resp) = try? await URLSession.shared.data(for: r) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }

    @discardableResult private func requestCallEnd() async -> Bool {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/call/end") else { return false }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let (_, resp) = try? await URLSession.shared.data(for: r) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }
}
