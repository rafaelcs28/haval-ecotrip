import AVKit
import SwiftUI

struct CameraRecordingsView: View {
    @StateObject private var store: CameraVideoStore
    @State private var endpoint: CameraLanEndpoint?
    @State private var showInternetConfirmation = false
    @State private var showSettings = false
    @State private var deletionTrip: CameraVideoTrip?
    @State private var shareItems: CameraShareItems?
    @State private var player: AVQueuePlayer?
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
        .onDisappear { discovery.stop(); store.closeCatalogAction(); player?.pause() }
        .confirmationDialog("Usar internet para carregar as gravações?", isPresented: $showInternetConfirmation) {
            Button("Usar internet") { Task { await store.confirmCatalogInternet() } }
            Button("Cancelar", role: .cancel) { store.closeCatalogAction() }
        } message: {
            Text("A autorização vale somente enquanto esta galeria estiver aberta.")
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
                        }
                        Spacer()
                        Button { Task { await download(trip, segment) } } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .disabled(endpoint != nil && trip.segments.isEmpty)
                        .accessibilityLabel("Baixar segmento \(segment.id)")
                    }
                }
                if trip.segments.isEmpty {
                    Text("Metadados de verificação ainda indisponíveis para esta gravação.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Reproduzir") { play(trip) }
                        Spacer()
                        Button("Compartilhar") { share(trip) }
                    }
                }
            } header: {
                HStack {
                    Text(trip.start.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Button(role: .destructive) { deletionTrip = trip } label: { Image(systemName: "trash") }
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
        let route: CameraDownloadRoute = endpoint == nil ? .internet : .lan
        if route == .internet && store.catalogState != .loaded(route: .internet, stale: false) {
            showInternetConfirmation = true; return
        }
        _ = try? await store.downloadSegment(tripID: trip.id, segment: segment, route: route,
                                              lanEndpoint: endpoint, bridgeURL: bridgeURL,
                                              bridgeToken: Settings.bridgeToken)
    }

    private func play(_ trip: CameraVideoTrip) {
        guard let urls = try? store.playbackURLs(for: trip) else { return }
        let queue = AVQueuePlayer(items: urls.map(AVPlayerItem.init(url:)))
        player = queue; queue.play()
    }

    private func share(_ trip: CameraVideoTrip) {
        guard let urls = try? store.shareURLs(for: trip) else { return }
        shareItems = CameraShareItems(urls: urls)
    }

    private func delete(_ trip: CameraVideoTrip) async {
        try? await store.deleteRecordings([trip.id], confirmed: true, bridgeURL: bridgeURL,
                                          bridgeToken: Settings.bridgeToken)
        await store.reloadCatalog()
    }

    private var bridgeURL: URL {
        URL(string: BridgeRouter.shared.currentURL) ?? URL(string: "https://invalid.invalid")!
    }
    private func routeLabel(_ route: CameraDownloadRoute) -> String { route == .lan ? "LAN" : "Internet" }
}

private struct CameraShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
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
