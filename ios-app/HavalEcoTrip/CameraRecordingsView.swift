import AVKit
import SwiftUI

struct CameraRecordingsView: View {
    @StateObject private var store: CameraVideoStore
    @State private var endpoint: CameraLanEndpoint?
    @State private var showInternetConfirmation = false
    @State private var showDownloadInternetConfirmation = false
    @State private var pendingDownload: CameraPendingDownload?
    @State private var showSettings = false
    @State private var deletionTrip: CameraVideoTrip?
    @State private var shareItems: CameraShareItems?
    @State private var player: AVQueuePlayer?
    @State private var errorMessage: String?
    private let discovery: LANDiscovery

    @MainActor
    init(store: CameraVideoStore? = nil, discovery: LANDiscovery? = nil) {
        _store = StateObject(wrappedValue: store ?? CameraVideoStore())
        self.discovery = discovery ?? LANDiscovery()
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.trips.isEmpty { emptyState } else { recordingsList }
            }
            .navigationTitle("Câmeras do veículo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Configurações da câmera")
                }
            }
            .safeAreaInset(edge: .top) { statusBanner }
            .refreshable { await store.reloadCatalog(); updatePrompt() }
        }
        .task { startDiscoveryAndLoad() }
        .onDisappear {
            discovery.stop(); player?.pause()
            Task { await store.closeCatalogAction() }
        }
        .confirmationDialog("Usar internet para carregar as gravações?", isPresented: $showInternetConfirmation) {
            Button("Usar internet") { Task { await store.confirmCatalogInternet() } }
            Button("Cancelar", role: .cancel) { Task { await store.closeCatalogAction() } }
        } message: {
            Text("A autorização vale somente enquanto esta galeria estiver aberta.")
        }
        .confirmationDialog("Usar internet para baixar este vídeo?", isPresented: $showDownloadInternetConfirmation) {
            Button("Usar internet") { confirmRemoteDownload() }
            Button("Cancelar", role: .cancel) { cancelRemoteDownload() }
        } message: {
            Text("A autorização vale somente para este download. Outro vídeo pedirá confirmação novamente.")
        }
        .confirmationDialog("Apagar esta gravação concluída?", item: $deletionTrip) { trip in
            Button("Apagar gravação", role: .destructive) { Task { await delete(trip) } }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in Text("Esta confirmação é separada do download e não pode ser desfeita.") }
        .sheet(isPresented: $showSettings) {
            CameraSettingsView(store: store, bridgeURL: bridgeURL, bridgeToken: Settings.bridgeToken)
        }
        .sheet(item: $shareItems) { value in ActivityView(items: value.urls) }
        .sheet(isPresented: Binding(get: { player != nil }, set: { if !$0 { player?.pause(); player = nil } })) {
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
        }
        .alert("Não foi possível concluir a ação", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Erro desconhecido.") }
    }

    private var recordingsList: some View {
        List(store.trips) { trip in
            Section {
                ForEach(trip.segments) { segment in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Segmento \(segment.id)")
                            Text(ByteCountFormatter.string(fromByteCount: Int64(segment.byteSize), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(localStateLabel(trip, segment)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.isDownloading(tripID: trip.id, segmentID: segment.id) {
                            Button(role: .cancel) {
                                Task { await store.cancelDownload(tripID: trip.id, segmentID: segment.id) }
                            } label: { Label("Cancelar", systemImage: "xmark.circle") }
                        } else {
                            Button { Task { await download(trip, segment) } } label: {
                                Image(systemName: downloadIcon(trip, segment))
                            }
                            .disabled(isVerified(trip, segment))
                            .accessibilityLabel(isVerified(trip, segment) ?
                                                "Segmento \(segment.id) verificado" : "Baixar segmento \(segment.id)")
                        }
                    }
                }
                if trip.segments.isEmpty {
                    Text("Metadados de verificação ainda indisponíveis para esta gravação.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Reproduzir") { play(trip) }
                            .disabled(!store.isTripReadyForPlayback(trip) || store.hasActiveDownload(for: trip))
                        Spacer()
                        Button("Compartilhar") { share(trip) }
                            .disabled(!store.isTripReadyForPlayback(trip) || store.hasActiveDownload(for: trip))
                    }
                }
            } header: {
                HStack {
                    Text(trip.start.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Button(role: .destructive) { deletionTrip = trip } label: { Image(systemName: "trash") }
                        .disabled(store.hasActiveDownload(for: trip))
                        .accessibilityLabel("Apagar gravação")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView("Nenhuma gravação concluída", systemImage: "video.slash",
                               description: Text("Viagens ativas e arquivos incompletos não aparecem aqui."))
    }

    @ViewBuilder private var statusBanner: some View {
        switch store.catalogState {
        case .loaded(let route, let stale):
            Label(stale ? "Catálogo desatualizado · \(routeLabel(route))" : routeLabel(route),
                  systemImage: route == .lan ? "wifi" : "network")
                .font(.caption).padding(8).frame(maxWidth: .infinity).background(.thinMaterial)
        case .offline(let stale):
            Label(stale ? "Offline · mostrando catálogo salvo" : "Carro offline", systemImage: "wifi.slash")
                .font(.caption).padding(8).frame(maxWidth: .infinity).background(.thinMaterial)
        case .loading:
            ProgressView("Carregando gravações…").font(.caption).padding(8)
        default: EmptyView()
        }
        switch store.downloadState {
        case .downloading(let route, let progress):
            ProgressView("\(routeLabel(route)) · \(Int(progress * 100))%", value: progress)
                .padding(.horizontal)
        case .failed: Text("Download interrompido; a parte verificada pode ser retomada.").font(.caption)
        case .cancelled: Text("Download cancelado.").font(.caption)
        default: EmptyView()
        }
    }

    private func startDiscoveryAndLoad() {
        discovery.onResolve = { value in
            Task { @MainActor in
                endpoint = value.map { CameraLanEndpoint(host: $0.0, port: $0.1) }
                await store.loadCatalog(lanEndpoint: endpoint, bridgeURL: bridgeURL, bridgeToken: Settings.bridgeToken)
                updatePrompt()
            }
        }
        discovery.start()
        Task {
            await store.loadCatalog(lanEndpoint: endpoint, bridgeURL: bridgeURL, bridgeToken: Settings.bridgeToken)
            updatePrompt()
        }
    }

    private func updatePrompt() { showInternetConfirmation = store.catalogState == .askingInternet }

    private func download(_ trip: CameraVideoTrip, _ segment: CameraVideoSegment) async {
        switch store.beginDownloadAction(lanAvailable: endpoint != nil) {
        case .useLAN:
            await performDownload(trip, segment, route: .lan)
        case .askInternet:
            pendingDownload = CameraPendingDownload(trip: trip, segment: segment)
            showDownloadInternetConfirmation = true
        case .offline:
            await store.closeDownloadAction()
        }
    }

    private func confirmRemoteDownload() {
        guard let pendingDownload else { return }
        self.pendingDownload = nil
        store.confirmDownloadInternet()
        Task { await performDownload(pendingDownload.trip, pendingDownload.segment, route: .internet) }
    }

    private func cancelRemoteDownload() {
        pendingDownload = nil
        Task { await store.closeDownloadAction() }
    }

    private func performDownload(_ trip: CameraVideoTrip, _ segment: CameraVideoSegment,
                                 route: CameraDownloadRoute) async {
        do {
            _ = try await store.downloadSegment(tripID: trip.id, segment: segment, route: route,
                                                 lanEndpoint: endpoint, bridgeURL: bridgeURL,
                                                 bridgeToken: Settings.bridgeToken)
        } catch {
            if route == .lan, error is URLError || (error as? CameraVideoError) == .offline {
                _ = store.beginDownloadAction(lanAvailable: false)
                pendingDownload = CameraPendingDownload(trip: trip, segment: segment)
                showDownloadInternetConfirmation = true
            } else if !(error is CancellationError) {
                errorMessage = actionError(error, operation: "baixar o segmento")
            }
        }
    }

    private func play(_ trip: CameraVideoTrip) {
        do {
            let queue = AVQueuePlayer(items: try store.playbackURLs(for: trip).map(AVPlayerItem.init(url:)))
            player = queue; queue.play()
        } catch { errorMessage = actionError(error, operation: "reproduzir a gravação") }
    }

    private func share(_ trip: CameraVideoTrip) {
        do { shareItems = CameraShareItems(urls: try store.shareURLs(for: trip)) }
        catch { errorMessage = actionError(error, operation: "compartilhar a gravação") }
    }

    private func delete(_ trip: CameraVideoTrip) async {
        do {
            try await store.deleteRecordings([trip.id], confirmed: true, bridgeURL: bridgeURL,
                                             bridgeToken: Settings.bridgeToken)
            await store.reloadCatalog()
        } catch { errorMessage = actionError(error, operation: "apagar a gravação") }
    }

    private var bridgeURL: URL {
        URL(string: BridgeRouter.shared.currentURL) ?? URL(string: "https://invalid.invalid")!
    }
    private func routeLabel(_ route: CameraDownloadRoute) -> String { route == .lan ? "LAN" : "Internet" }

    private func isVerified(_ trip: CameraVideoTrip, _ segment: CameraVideoSegment) -> Bool {
        if case .verified = store.localState(tripID: trip.id, segment: segment) { return true }
        return false
    }

    private func downloadIcon(_ trip: CameraVideoTrip, _ segment: CameraVideoSegment) -> String {
        isVerified(trip, segment) ? "checkmark.circle.fill" : "arrow.down.circle"
    }

    private func localStateLabel(_ trip: CameraVideoTrip, _ segment: CameraVideoSegment) -> String {
        switch store.localState(tripID: trip.id, segment: segment) {
        case .missing: return "Não baixado"
        case .partial(let route, let bytes): return "Parcial · \(routeLabel(route)) · \(bytes) bytes"
        case .verified: return "Verificado"
        case .invalid: return "Arquivo local inválido"
        }
    }

    private func actionError(_ error: Error, operation: String) -> String {
        switch error {
        case CameraVideoError.insufficientStorage: return "Espaço insuficiente para \(operation). Libere armazenamento e tente novamente."
        case CameraVideoError.incompleteFiles: return "Baixe e verifique todos os segmentos antes de \(operation)."
        case CameraVideoError.duplicateDownload: return "Este segmento já está sendo baixado."
        case CameraVideoError.offline, CameraVideoError.disconnected:
            return "A câmera ou a ponte ficou offline ao tentar \(operation). Tente novamente."
        default: return "Falha ao tentar \(operation). Tente novamente."
        }
    }
}

private struct CameraShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct CameraPendingDownload {
    let trip: CameraVideoTrip
    let segment: CameraVideoSegment
}

private extension View {
    func confirmationDialog<Item: Identifiable, Actions: View, Message: View>(
        _ title: String, item: Binding<Item?>,
        @ViewBuilder actions: @escaping (Item) -> Actions,
        @ViewBuilder message: @escaping (Item) -> Message
    ) -> some View {
        confirmationDialog(title, isPresented: Binding(get: { item.wrappedValue != nil },
                                                       set: { if !$0 { item.wrappedValue = nil } })) {
            if let value = item.wrappedValue { actions(value) }
        } message: {
            if let value = item.wrappedValue { message(value) }
        }
    }
}
