import SwiftUI
import WebKit

/// Mini-WebView no canto inferior direito do cluster. URL configurável em
/// Settings (default YouTube). Pode ser ocultado/movido conforme uso.
struct MiniPlayerView: View {
    @AppStorage("mini_player_url") private var url: String = "https://m.youtube.com"
    @AppStorage("mini_player_visible") private var visible: Bool = true
    @State private var showUrlEditor = false
    @State private var editorText: String = ""

    var body: some View {
        if visible {
            ZStack(alignment: .topLeading) {
                MiniWebView(urlString: url)
                    .cornerRadius(14)
                controls
                    .padding(6)
            }
            .frame(width: 480, height: 280)
            .background(Color.black)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 12)
            .padding(16)
            .sheet(isPresented: $showUrlEditor) {
                NavigationStack {
                    Form {
                        Section("URL do mini-player") {
                            TextField("https://m.youtube.com/...", text: $editorText)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                        }
                        Section("Sugestões") {
                            Button("YouTube") { editorText = "https://m.youtube.com" }
                            Button("YouTube Music") { editorText = "https://music.youtube.com" }
                            Button("Spotify Web") { editorText = "https://open.spotify.com" }
                            Button("Twitch") { editorText = "https://m.twitch.tv" }
                        }
                    }
                    .navigationTitle("MiniPlayer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancelar") { showUrlEditor = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("OK") {
                                url = editorText
                                showUrlEditor = false
                            }.bold()
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                editorText = url
                showUrlEditor = true
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Button { visible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }
}

private struct MiniWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.backgroundColor = .black
        web.scrollView.bouncesZoom = false
        web.scrollView.maximumZoomScale = 1.0
        if let u = URL(string: urlString) {
            web.load(URLRequest(url: u))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard let u = URL(string: urlString) else { return }
        if web.url != u {
            web.load(URLRequest(url: u))
        }
    }
}

/// Botão flutuante (canto inferior direito) pra REABRIR o MiniPlayer
/// quando foi fechado com o X. Some quando o player está visível.
struct MiniPlayerToggleButton: View {
    @AppStorage("mini_player_visible") private var visible: Bool = true

    var body: some View {
        if !visible {
            Button { visible = true } label: {
                Image(systemName: "play.tv")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            .padding(.bottom, 16)
            .padding(.trailing, 16)
        }
    }
}
