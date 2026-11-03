import SwiftUI

struct CameraSettingsView: View {
    @ObservedObject var store: CameraVideoStore
    let bridgeURL: URL
    let bridgeToken: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let settings = store.settings {
                    recording(settings)
                    remote(settings)
                    quality(settings)
                    stamps(settings)
                } else if store.settingsState == .failed {
                    ContentUnavailableView("Configurações indisponíveis", systemImage: "exclamationmark.triangle")
                } else { ProgressView() }

                if store.settingsState == .conflict {
                    Text("A câmera mudou estas opções. O estado mais recente substituiu a edição.")
                        .font(.caption).foregroundStyle(.orange)
                } else if store.settingsState == .failed {
                    Text("A alteração falhou e o valor anterior foi restaurado.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .disabled(store.settingsState == .saving)
            .navigationTitle("Configurações da câmera")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if store.settingsState == .saving { ProgressView() }
                    else { Button("OK") { dismiss() } }
                }
            }
        }
        .task { await store.loadSettings(bridgeURL: bridgeURL, bridgeToken: bridgeToken) }
    }

    private func recording(_ value: CameraSettings) -> some View {
        Section("Gravação") {
            settingToggle("Gravação automática", value.automaticRecording) { .init(automaticRecording: $0) }
            settingToggle("Gravar live estacionado", value.recordParkedLive) { .init(recordParkedLive: $0) }
            settingToggle("Exclusão automática", value.automaticDeletion) { .init(automaticDeletion: $0) }
            Picker("Reserva", selection: binding(value.reserveGB) { .init(reserveGB: $0) }) {
                ForEach([1, 5, 10, 20], id: \.self) { Text("\($0) GB").tag($0) }
            }
        }
    }

    private func remote(_ value: CameraSettings) -> some View {
        Section("Acesso remoto") {
            settingToggle("Live pela internet", value.remoteLive) { .init(remoteLive: $0) }
            settingToggle("Downloads pela internet", value.remoteDownloads) { .init(remoteDownloads: $0) }
        }
    }

    private func quality(_ value: CameraSettings) -> some View {
        Section("Qualidade") {
            Picker("Vídeo", selection: binding(value.quality) { .init(quality: $0) }) {
                Text("Econômica").tag(CameraVideoQuality.economy)
                Text("Padrão").tag(CameraVideoQuality.standard)
                Text("Alta").tag(CameraVideoQuality.high)
            }
            Picker("Posição dos carimbos", selection: binding(value.overlayPosition) { .init(overlayPosition: $0) }) {
                ForEach(CameraOverlayPosition.allCases, id: \.self) { Text(label($0)).tag($0) }
            }
        }
    }

    private func stamps(_ value: CameraSettings) -> some View {
        Section("Carimbos") {
            settingToggle("Ativar carimbos", value.overlayMaster) { .init(overlayMaster: $0) }
            settingToggle("Data e hora", value.overlayDateTime) { .init(overlayDateTime: $0) }
            settingToggle("Velocidade", value.overlaySpeed) { .init(overlaySpeed: $0) }
            settingToggle("Aceleração", value.overlayAcceleration) { .init(overlayAcceleration: $0) }
            settingToggle("Estado de condução", value.overlayDriveState) { .init(overlayDriveState: $0) }
            settingToggle("Regeneração", value.overlayDecelerationRegen) { .init(overlayDecelerationRegen: $0) }
        }
    }

    private func settingToggle(_ title: String, _ value: Bool,
                               patch: @escaping (Bool) -> CameraSettingsPatch) -> some View {
        Toggle(title, isOn: binding(value, patch: patch))
    }

    private func binding<T>(_ value: T, patch: @escaping (T) -> CameraSettingsPatch) -> Binding<T> {
        Binding(get: { value }, set: { next in
            Task { await store.updateSettings(patch(next), bridgeURL: bridgeURL, bridgeToken: bridgeToken) }
        })
    }

    private func label(_ position: CameraOverlayPosition) -> String {
        switch position {
        case .topLeft: "Superior esquerda"
        case .topRight: "Superior direita"
        case .bottomLeft: "Inferior esquerda"
        case .bottomRight: "Inferior direita"
        }
    }
}
