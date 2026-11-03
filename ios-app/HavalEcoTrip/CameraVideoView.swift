import AVFoundation
import SwiftUI
import UIKit

struct CameraVideoView: View {
    @StateObject private var session: CameraLiveSession
    @Environment(\.dismiss) private var dismiss

    init() {
        _session = StateObject(wrappedValue: CameraLiveSession(
            bridgeURL: { BridgeRouter.shared.currentURL },
            bridgeToken: { Settings.bridgeToken }
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                video
                status
                controls
                Text("Vídeo ao vivo usa cerca de \(session.quality.estimatedGBPerHour, specifier: "%.1f") GB/h em dados móveis.")
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
                    Button("Fechar") { Task { await session.stop(); dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(session.state != .idle)
        .task { session.startDiscovery() }
        .onDisappear { session.stopDiscovery() }
        .alert("Usar internet?", isPresented: internetPrompt) {
            Button("Cancelar", role: .cancel) { Task { await session.cancelInternet() } }
            Button("Usar internet") { Task { await session.confirmInternet() } }
        } message: {
            Text("A conexão LAN não está disponível. O vídeo em \(qualityName) usa cerca de \(session.quality.estimatedGBPerHour, specifier: "%.1f") GB/h.")
        }
    }

    private var video: some View {
        ZStack {
            Color.black
            if let layer = session.displayLayer {
                CameraVideoLayerView(layer: layer)
            }
            if session.state != .live {
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
            if let route = session.route {
                Text(route == .lan ? "LAN" : "Internet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.text2)
            }
            Spacer()
            if let latency = session.latencyMs, session.state == .live {
                Text("~\(latency) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.text2)
            }
        }
        .padding(12)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .idle, .offline, .error:
            Button { Task { await session.start() } } label: {
                Label(session.state == .idle ? "Ver ao vivo" : "Tentar novamente", systemImage: "video.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(DS.teal, in: Capsule())
            }
            .buttonStyle(.plain)
        case .connecting, .askingInternet, .live, .degraded:
            Button { Task { await session.stop() } } label: {
                Label("Encerrar vídeo", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.red)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(DS.red.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var stateText: String {
        switch session.state {
        case .idle: "Pronto para conectar"
        case .connecting: "Conectando…"
        case .askingInternet: "Aguardando confirmação"
        case .live: "Ao vivo"
        case .degraded: "Sinal interrompido — reconectando"
        case .offline: "Carro offline"
        case .error(let message): message
        }
    }

    private var stateIcon: String {
        switch session.state {
        case .live: "video.fill"
        case .connecting, .degraded: "arrow.triangle.2.circlepath"
        case .askingInternet: "wifi.exclamationmark"
        case .offline: "car.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "video"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .live: DS.green
        case .connecting, .askingInternet, .degraded: DS.yellow
        case .error: DS.red
        case .idle, .offline: DS.muted
        }
    }

    private var internetPrompt: Binding<Bool> {
        Binding(get: { session.state == .askingInternet }, set: { _ in })
    }

    private var qualityName: String {
        switch session.quality {
        case .economy: "qualidade econômica"
        case .standard: "qualidade padrão"
        case .high: "qualidade alta"
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
