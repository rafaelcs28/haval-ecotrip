import AVFoundation
import SwiftUI
import UIKit

struct CameraVideoView: View {
    @StateObject private var havalSession: CameraLiveSession
    @StateObject private var dashcamSession: CarCamViewerSession
    @State private var selectedSource = CameraLiveSource.haval
    @State private var isSwitchingSource = false
    @Environment(\.dismiss) private var dismiss

    init() {
        _havalSession = StateObject(wrappedValue: CameraLiveSession(
            bridgeURL: { BridgeRouter.shared.currentURL },
            bridgeToken: { Settings.bridgeToken }
        ))
        _dashcamSession = StateObject(wrappedValue: .live(token: Settings.bridgeToken))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Fonte", selection: sourceSelection) {
                    ForEach(CameraLiveSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSwitchingSource)
                video
                status
                controls
                    .disabled(isSwitchingSource)
                Text(usageText)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(18)
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Câmeras do carro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { Task { await close() } }
                }
            }
        }
        .interactiveDismissDisabled(havalSession.state != .idle || dashcamSession.state != .idle)
        .task { havalSession.startDiscovery() }
        .onDisappear {
            havalSession.stopDiscovery()
            Task { await havalSession.stop(); await dashcamSession.stop() }
        }
        .alert("Usar internet?", isPresented: internetPrompt) {
            Button("Cancelar", role: .cancel) { Task { await havalSession.cancelInternet() } }
            Button("Usar internet") { Task { await havalSession.confirmInternet() } }
        } message: {
            Text("A conexão LAN não está disponível. O vídeo em \(qualityName) usa cerca de \(havalSession.quality.estimatedGBPerHour, specifier: "%.1f") GB/h.")
        }
    }

    private var video: some View {
        ZStack {
            Color.black
            if selectedSource == .haval, let layer = havalSession.displayLayer {
                CameraVideoLayerView(layer: layer)
            } else if selectedSource == .dashcam, let track = dashcamSession.videoTrack {
                CarCamVideoSurface(track: track)
            }
            if !isCurrentSourceLive {
                VStack(spacing: 9) {
                    Image(systemName: stateIcon).font(.system(size: 28)).foregroundStyle(stateColor)
                    Text(stateText).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                }
            }
        }
        .aspectRatio(1760.0 / 720.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.white.opacity(0.10)))
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            Text(stateText).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text)
            if selectedSource == .haval, let route = havalSession.route {
                Text(route == .lan ? "LAN" : "Internet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.text2)
            }
            Spacer()
            if selectedSource == .dashcam, dashcamSession.state == .playing {
                Text("Tailscale").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text2)
            } else if selectedSource == .haval,
                      let latency = havalSession.latencyMs,
                      havalSession.state == .live {
                Text("~\(latency) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.text2)
            }
        }
        .padding(12)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var controls: some View {
        if isCurrentSourceActive {
            Button { Task { await stopCurrentSource() } } label: {
                Label("Encerrar vídeo", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.red)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(DS.red.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button { Task { await startCurrentSource() } } label: {
                Label(isCurrentSourceIdle ? "Ver ao vivo" : "Tentar novamente", systemImage: "video.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(DS.teal, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var stateText: String {
        if selectedSource == .dashcam {
            switch dashcamSession.state {
            case .idle: return "Pronto para conectar"
            case .connecting: return "Conectando à dashcam…"
            case .playing: return "Ao vivo"
            case .failed(let error): return dashcamErrorText(error)
            }
        }
        switch havalSession.state {
        case .idle: return "Pronto para conectar"
        case .connecting: return "Conectando…"
        case .askingInternet: return "Aguardando confirmação"
        case .live: return "Ao vivo"
        case .degraded: return "Sinal interrompido — reconectando"
        case .offline: return "Carro offline"
        case .error(let message): return message
        }
    }

    private var stateIcon: String {
        if selectedSource == .dashcam {
            switch dashcamSession.state {
            case .playing: return "video.fill"
            case .connecting: return "arrow.triangle.2.circlepath"
            case .failed: return "exclamationmark.triangle.fill"
            case .idle: return "video"
            }
        }
        switch havalSession.state {
        case .live: return "video.fill"
        case .connecting, .degraded: return "arrow.triangle.2.circlepath"
        case .askingInternet: return "wifi.exclamationmark"
        case .offline: return "car.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "video"
        }
    }

    private var stateColor: Color {
        if selectedSource == .dashcam {
            switch dashcamSession.state {
            case .playing: return DS.green
            case .connecting: return DS.yellow
            case .failed: return DS.red
            case .idle: return DS.muted
            }
        }
        switch havalSession.state {
        case .live: return DS.green
        case .connecting, .askingInternet, .degraded: return DS.yellow
        case .error: return DS.red
        case .idle, .offline: return DS.muted
        }
    }

    private var internetPrompt: Binding<Bool> {
        Binding(get: { selectedSource == .haval && havalSession.state == .askingInternet }, set: { _ in })
    }

    private var qualityName: String {
        switch havalSession.quality {
        case .economy: "qualidade econômica"
        case .standard: "qualidade padrão"
        case .high: "qualidade alta"
        }
    }

    private var sourceSelection: Binding<CameraLiveSource> {
        Binding(get: { selectedSource }, set: { source in Task { await switchSource(to: source) } })
    }

    private var isCurrentSourceLive: Bool {
        selectedSource == .haval ? havalSession.state == .live : dashcamSession.state == .playing
    }

    private var isCurrentSourceActive: Bool {
        if selectedSource == .dashcam {
            return dashcamSession.state == .connecting || dashcamSession.state == .playing
        }
        switch havalSession.state {
        case .connecting, .askingInternet, .live, .degraded: return true
        case .idle, .offline, .error: return false
        }
    }

    private var isCurrentSourceIdle: Bool {
        selectedSource == .haval ? havalSession.state == .idle : dashcamSession.state == .idle
    }

    private var usageText: String {
        selectedSource == .haval
            ? "Vídeo ao vivo usa cerca de \(String(format: "%.1f", havalSession.quality.estimatedGBPerHour)) GB/h em dados móveis."
            : "Dashcam ao vivo usa a conexão Tailscale fixa do carro."
    }

    private func startCurrentSource() async {
        guard !isSwitchingSource else { return }
        if selectedSource == .haval { await havalSession.start() }
        else { await dashcamSession.start() }
    }

    private func stopCurrentSource() async {
        if selectedSource == .haval { await havalSession.stop() }
        else { await dashcamSession.stop() }
    }

    private func switchSource(to source: CameraLiveSource) async {
        guard !isSwitchingSource else { return }
        let action = CameraSourceSelectionPolicy.stopAction(from: selectedSource, to: source)
        guard action != .none else { return }
        isSwitchingSource = true
        if action == .stopHaval { await havalSession.stop() }
        else { await dashcamSession.stop() }
        selectedSource = source
        isSwitchingSource = false
    }

    private func close() async {
        await havalSession.stop()
        await dashcamSession.stop()
        dismiss()
    }

    private func dashcamErrorText(_ error: CarCamViewerError) -> String {
        switch error {
        case .credentialUnavailable: "Token indisponível"
        case .unauthorized: "Token recusado"
        case .viewerExists: "Já existe uma visualização ativa"
        case .tailscaleUnavailable: "Tailscale indisponível"
        case .setupTimeout: "Tempo de conexão esgotado"
        case .mediaSetupFailed, .mediaRequired: "Mídia da dashcam indisponível"
        case .bodyTooLarge, .unsupportedMediaType, .invalidSDP: "Resposta de vídeo inválida"
        case .teardownFailed: "Falha ao encerrar a sessão"
        case .invalidResponse, .invalidLocation, .tlsPinMismatch, .peerConnectionFailed: "Não foi possível conectar à dashcam"
        }
    }
}

private struct CameraVideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.videoLayer = layer
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        uiView.videoLayer = layer
    }
}

private final class LayerHostView: UIView {
    var videoLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let videoLayer { layer.addSublayer(videoLayer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.frame = bounds
    }
}
