//  Carro3DView.swift
//  Visualizador 3D do carro (Haval-H6-3D, de netseek) dentro do Cockpit.
//
//  A página vem do bridge (/3d/), não do bundle: são ~92 MB de modelo e textura.
//  Servida com `immutable` e cache de 1 ano, ela baixa UMA vez e reusa — o IPA fica
//  pequeno e o repositório limpo (os assets são de terceiro, e este repo é público).
//  O custo é precisar de rede na primeira abertura, ou se o iOS despejar o cache.
//
//  Os DADOS não vêm do bridge: vêm da LAN direta com o carro, que é o que o Cockpit
//  já faz. O WebView não abre rede nenhuma pra telemetria — quem alimenta é este
//  arquivo, pelo mesmo desenho do ClusterWebView (Swift → JS por evaluateJavaScript).

import SwiftUI
import WebKit

struct Carro3DView: View {
    @EnvironmentObject var publisher: BridgePublisher
    @AppStorage("bridge_base_url") private var bridgeBase = "https://bridge.malha.dev"

    var body: some View {
        // Sem palco de 1920 escalado: o shim manda as medidas REAIS do iPad pro
        // visualizador por `onAndroidShellLayout`, que é a porta que o autor abriu
        // pro hospedeiro nativo. Escalar era contornar o layout deitado; agora o
        // layout é o do iPad.
        Carro3DWeb(baseUrl: bridgeBase, publisher: publisher)
            .ignoresSafeArea()
            .navigationTitle("Carro em 3D")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct Carro3DWeb: UIViewRepresentable {
    let baseUrl: String
    let publisher: BridgePublisher

    func makeCoordinator() -> Coord { Coord(publisher: publisher) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Comandos do visualizador (vidro, teto, cortina) chegam por aqui. No carro
        // quem atende é o `TelemetryBridge` que o APK injeta; no iPad não existe
        // ninguém, e o próprio viewer registra "no Impulse bridge for <cmd>" e
        // engole o toque — era o botão que não surtia efeito.
        cfg.userContentController.add(context.coordinator, name: "carro3d")
        // Store persistente (o padrão) é o que guarda os 92 MB entre aberturas.
        cfg.websiteDataStore = .default()

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { web.isInspectable = true }

        // `native=1` faz o SERVIDOR marcar que quem alimenta é o app — o shim da
        // página então não abre fetch nem WebSocket. Injetar isso do lado do app
        // correria com o carregamento; pelo servidor a ordem é garantida.
        // `hq=1` TIRA a flag `android` que a rota força. Ela some porque é ela que
        // esconde a barra de ferramentas do visualizador (`dayNightDisplay` vai a
        // 'none' quando `_androidApp`) — no carro isso é certo, o launcher do carro
        // põe a barra dele; aqui deixava o iPad sem engrenagem e sem como adicionar
        // widget. `debug=1` liga o shell preview, que é o que traz os quadros de
        // widget de volta sem se declarar Android.
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        if let url = URL(string: base + "/3d/?native=1&hq=1&debug=1") {
            web.load(URLRequest(url: url))
        }
        context.coordinator.web = web
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let publisher: BridgePublisher
        weak var web: WKWebView?
        private var timer: Timer?
        private var pronto = false
        private var ultimo: [String: String] = [:]
        private var ultimoCloudJson = ""

        init(publisher: BridgePublisher) { self.publisher = publisher }
        deinit { timer?.invalidate() }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            pronto = true
            ultimo.removeAll()          // recarregou: o viewer esqueceu, reenvia tudo
            // 4 Hz. A LAN entrega 10, mas cada push redesenha e o olho não vê a
            // diferença num modelo 3D — a bateria vê.
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.empurra()
            }
        }

        /// Comando do visualizador → o MESMO caminho que o painel já usa
        /// (`postCommand`, que escolhe WS da LAN ou nuvem). Não invento rota nova:
        /// o vocabulário do viewer é traduzido pros endpoints que o carro atende.
        ///
        /// Vidro INDIVIDUAL não entra: nem o bridge nem a via LAN do APK têm esse
        /// comando — só "todos os vidros". Mandar window-all quando o toque foi num
        /// vidro só seria pior que não fazer nada.
        func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let d = msg.body as? [String: Any],
                  let cmd = d["cmd"] as? String else { return }
            let valor = Int(String(describing: d["value"] ?? "")) ?? 0

            func manda(_ path: String, _ chave: String, _ v: Int) {
                Task { await publisher.postCommand(path: path, body: [chave: v]) }
            }
            switch cmd {
            // vidros: 0=aberto · 1=fechado · 3=entreaberto
            case "open_windows":      manda("/api/vehicle/window-all", "level", 0)
            case "close_windows":     manda("/api/vehicle/window-all", "level", 1)
            // teto solar: 0=fechado · 200=ventilação · 10..100=abertura
            case "open_sunroof":      manda("/api/vehicle/skylight", "level", 100)
            case "close_sunroof":     manda("/api/vehicle/skylight", "level", 0)
            case "set_sunroof_level": manda("/api/vehicle/skylight", "level", valor)
            // cortina: 0=fechada · 100=aberta
            case "open_curtain":      manda("/api/vehicle/shade", "level", 100)
            case "close_curtain":     manda("/api/vehicle/shade", "level", 0)
            case "set_curtain_level": manda("/api/vehicle/shade", "level", valor)
            // porta-malas vai por Home Assistant, que não atende pela LAN
            case "toggle_trunk":
                Task { await publisher.postCommand(path: "/api/action/trunk_open",
                                                   body: [:], lanCapable: false) }
            default:
                print("[carro3d] comando sem rota no carro: \(cmd) \(valor)")
            }
        }

        /// Repassa as chaves do CarConstants pro viewer pelo mesmo ponto de entrada
        /// que o Android usa (`window.onCarDataUpdate`) — pra ele não há diferença
        /// entre rodar no head unit e aqui.
        ///
        /// A fonte é o snapshot que o BridgePublisher JÁ recebe pelo /ws/state; não
        /// abro conexão própria, senão seriam dois clientes no mesmo servidor do APK.
        private func empurra() {
            guard pronto, let w = web else { return }
            let o = publisher.ultimoSnapshotLan
            // Sem os blocos crus não há o que repassar por esta via. Eles só existem
            // na LAN direta e a partir do APK v6.228 — fora disso o viewer ficava
            // MUDO, que é o "abrir a porta não surte efeito no desenho": o dado
            // nunca chegava, o mapa de chave estava certo o tempo todo.
            guard o["car_raw"] != nil || o["car"] != nil else { empurraDaNuvem(); return }
            var pares: [(String, String)] = []
            // `car_raw` primeiro e `car` depois: em conflito vence o valor curado.
            for bloco in ["car_raw", "car"] {
                guard let m = o[bloco] as? [String: Any] else { continue }
                for (k, v) in m {
                    if v is NSNull { continue }
                    let s = String(describing: v)
                    if ultimo[k] == s { continue }
                    ultimo[k] = s
                    pares.append((k, s))
                }
            }
            guard !pares.isEmpty else { return }
            // Um evaluateJavaScript por lote: cada chamada cruza a ponte pro processo
            // do WebView.
            let js = pares.map { k, v in
                "window.onCarDataUpdate&&window.onCarDataUpdate(\(cita(k)),\(cita(v)));"
            }.joined()
            w.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Sem LAN (ou com APK velho), o estado vem da nuvem — em campos
        /// NORMALIZADOS, não nas chaves do CarConstants. Quem traduz é o shim da
        /// própria página, que já faz exatamente isso quando roda fora do app: um
        /// tradutor só, nos dois caminhos, em vez de dois que discordam.
        private func empurraDaNuvem() {
            guard let w = web else { return }
            let st = publisher.ultimoEstadoCloud
            guard !st.isEmpty,
                  let d = try? JSONSerialization.data(withJSONObject: st, options: [.sortedKeys]),
                  let j = String(data: d, encoding: .utf8), j != ultimoCloudJson else { return }
            ultimoCloudJson = j
            w.evaluateJavaScript(
                "window.__ecotripShim&&window.__ecotripShim.aplica&&window.__ecotripShim.aplica(\(j));",
                completionHandler: nil)
        }

        private func cita(_ s: String) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
                .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
    }
}
