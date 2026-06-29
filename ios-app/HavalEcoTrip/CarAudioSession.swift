//  CarAudioSession.swift
//  Escuta ao vivo da cabine: abre a sessão no carro (POST /api/audio/listen),
//  conecta no relay WS /ws/audio e toca o PCM que chega (carro→fone). Push-to-talk
//  captura o mic do iPhone e manda PCM pelo mesmo WS (fone→carro). Half-duplex.
//  Formato fixo: PCM16 LE mono 8kHz (casa com o APK e o bridge).

import AVFoundation
import Foundation

@MainActor
final class CarAudioSession: ObservableObject {
    enum State: Equatable { case idle, connecting, listening, error(String) }
    @Published var state: State = .idle
    @Published var talking = false
    @Published var level: Double = 0        // nível de entrada 0…1 (VU meter)
    @Published var reconnecting = false
    @Published var inCall = false           // chamada full-duplex ativa
    @Published var callStatus = ""          // "Chamando…", "Em chamada", "Encerrada"

    @Published private(set) var callMode = false

    private var reconnectAttempt = 0
    private let rate = 8000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private lazy var pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private var ws: URLSessionWebSocketTask?
    private var talkConverter: AVAudioConverter?
    private var tapInstalled = false
    private var micGranted = false

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

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
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        talking = false
        state = .idle
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
