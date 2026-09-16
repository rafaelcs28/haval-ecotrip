//
//  ConectividadeView.swift
//  Conectividade do carro: por onde o hotspot roteia, estado do 4G, prioridade de
//  WiFi e troca de rede — leitura e COMANDO.
//
//  O celular não fala com o Impulse. Quem tem acesso ao ContentProvider dele é o
//  EcoTrip dentro do carro, então tudo aqui é: POST /api/uplink/cmd → MQTT →
//  EcoTrip → provider.call() → Impulse. O resultado volta pelo caminho inverso.
//
//  Por isso os controles são OTIMISTAS COM RECONCILIAÇÃO: o toggle mexe na hora
//  (feedback imediato num app de carro), mas o valor exibido volta a ser o do
//  `uplink` do estado assim que ele chega. Se o Impulse recusar — e recusa: liberar
//  o 4G não garante 4G, outras regras (consumo, WiFi, AA/CarPlay) podem seguir
//  cortando — o toggle volta sozinho e o motivo aparece.
//
import SwiftUI

struct ConectividadeView: View {
    @ObservedObject private var store = CarStore.shared
    @State private var enviando: String?
    @State private var erro: String?
    @State private var redes: [String] = []
    @State private var buscandoRedes = false
    @State private var visiveis: [(ssid: String, nivel: Int, seg: Bool)] = []
    @State private var escaneando = false
    @State private var avisoWifiOff = false      // 1o passo da confirmação dupla
    @State private var confirmaWifiOff = false   // 2o passo
    /// Valor que o dono acabou de pedir, por controle. Enquanto existe, o toggle
    /// mostra ESTE valor (com spinner) em vez do estado do carro — sem isso o
    /// Toggle voltava sozinho na hora e parecia que o toque não fez nada.
    @State private var pendentes: [String: Bool] = [:]
    @State private var pollAtivo = false
    @State private var limiteGbLocal: Double?
    /// Consumo do ciclo, quando o Impulse informa (a tela dele já mostra).
    private var consumoTexto: String? {
        if let mb = store.uplinkRaw?["usadoMb"] as? Double, mb >= 0 {
            let lim = (store.uplinkRaw?["limiteMb"] as? Double) ?? 0
            let base = mb >= 1024 ? String(format: "%.2f GB", mb / 1024)
                                  : String(format: "%.0f MB", mb)
            return lim > 0 ? base + String(format: " de %.1f GB", lim / 1024) : base + " no ciclo"
        }
        for k in ["mobileUsedMb", "mobileUsageMb", "mobileCycleUsedMb", "mobileUsedBytes"] {
            if let v = snap[k] as? Int, v > 0 {
                let mb = k.hasSuffix("Bytes") ? Double(v) / 1_048_576 : Double(v)
                return mb >= 1024 ? String(format: "%.2f GB no ciclo", mb / 1024)
                                  : String(format: "%.0f MB no ciclo", mb)
            }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                estadoCard
                if store.uplinkVelho {
                    aviso("Última leitura \(store.uplinkIdadeTexto ?? "desconhecida"). O carro pode estar dormindo — o comando só chega quando ele acordar.", cor: DS.orange)
                }
                controles
                redesCard
                visiveisCard
                wifiRadioCard
                if let e = erro { aviso(e, cor: DS.red) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(DS.bg.ignoresSafeArea())
        .navigationTitle("Conectividade")
        .onAppear {
            store.start()
            // As regras de corte (WiFi, projeção, consumo, limite) NÃO vêm na query
            // do provider — só no snapshot que todo `call()` devolve. `listSavedWifi`
            // não altera nada e traz o snapshot completo, então serve de "ler estado".
            // Sem isto os toggles mostravam `false` por falta de dado, não por estarem
            // desligados — e divergiam da tela do carro.
            if snap.isEmpty { Task { await listar() } }
            pollAtivo = true
            Task { await pollEstado() }
        }
        .onDisappear { pollAtivo = false }
    }

    // MARK: estado

    private var estadoCard: some View {
        let u = store.uplinkRaw ?? [:]
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: iconeModo).foregroundStyle(corNivel)
                    Text(store.uplinkTexto ?? "Sem informação do carro")
                        .font(.system(size: DS.FontSize.strong, weight: .semibold))
                        .foregroundStyle(store.uplinkVelho ? DS.text2 : DS.text)
                    Spacer()
                    if store.uplinkVelho, let idade = store.uplinkIdadeTexto {
                        Text(idade).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                    }
                }
                linha("Modo de roteamento", store.uplinkModo.isEmpty ? "—" : store.uplinkModo)
                linha("Rede roteada", (u["wifi"] as? String) ?? "—")
                linha("Rede da tela", (u["wifiDaTela"] as? String) ?? "—")
                linha("4G utilizável", (u["quatroGOn"] as? Bool) == true ? "sim" : "não")
                // Consumo do ciclo. O Impulse ainda não expõe o campo (pedido em
                // 04/08); a linha fica com "—" pra o lugar já existir — quando ele
                // publicar, aparece sozinho, porque o APK copia o snapshot inteiro.
                linha("Consumo no ciclo", consumoTexto ?? "—")
                // O motivo do corte é o que evita a pergunta "liguei e não voltou, por quê?".
                if let motivo = u["motivoCorte"] as? String, !motivo.isEmpty {
                    linha("Motivo do corte", motivo)
                }
            }
        }
    }

    private var iconeModo: String { store.uplinkIconeSF }
    private var corNivel: Color {
        if store.uplinkVelho { return DS.muted }
        switch store.uplinkNivel {
        case "good": return DS.green
        case "warn": return DS.orange
        case "bad":  return DS.red
        default:     return DS.muted
        }
    }

    // MARK: comandos

    /// Snapshot do último comando, quando mais recente que o `uplink/status`.
    /// A partir do vc7261 cada `call()` devolve o estado resultante — é a
    /// confirmação imediata, e evita a UI ficar mostrando o valor antigo nos
    /// segundos até o próximo status chegar.
    private var snap: [String: Any] {
        guard let cmd = store.raw["uplink_cmd"] as? [String: Any],
              let ts = cmd["ts"] as? Double else { return [:] }
        // Descarta retido: é reentrega do broker, não resposta a um comando nosso.
        // Descarta velho (>90s): as regras só vivem no snapshot, então preferir um
        // antigo a nada seria mostrar passado como presente. O poll abaixo mantém
        // este valor fresco enquanto a tela está aberta.
        if (cmd["retido"] as? Bool) == true { return [:] }
        if Date().timeIntervalSince1970 - ts / 1000 > 90 { return [:] }
        return cmd
    }
    /// Mapa chave-do-snapshot → chave-do-status. A partir do vc7267 as regras vêm na
    /// query (portanto no `uplink/status`, que é o caminho de LEITURA). Quando estão
    /// lá, o status manda: é dado consultado, não a lembrança do último comando.
    private static let noStatus = [
        "mobileManualBlock": "manualBlock", "mobileBlockOnWifi": "blockOnWifi",
        "mobileBlockOnProjection": "blockProjecao", "mobileAutoblock": "autoblock",
        "wifiPriorityEnabled": "wifiPrioridade", "mobileControlEnabled": "controle4g",
    ]
    private func flag(_ chaveSnap: String, _ fallback: Bool) -> Bool {
        if let k = Self.noStatus[chaveSnap], let v = store.uplinkRaw?[k] as? Bool { return v }
        return (snap[chaveSnap] as? Bool) ?? fallback
    }
    /// Enquanto as regras não vêm no status, o poll de 4s é a única forma de lê-las.
    /// Quando vierem, ele para sozinho — sem release.
    private var statusTemRegras: Bool { store.uplinkRaw?["blockOnWifi"] is Bool }

    private var controles: some View {
        let u = store.uplinkRaw ?? [:]
        let quatroG = (u["quatroGOn"] as? Bool) == true
        return DSCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("DADOS MÓVEIS").font(.system(size: DS.FontSize.micro, weight: .bold))
                    .foregroundStyle(DS.muted).tracking(1)
                // Rótulo pela AÇÃO: "bloquear" descreve o que o toque faz. O estado
                // atual fica no card de cima.
                // `mobileManualBlock` e NÃO `mobileBlocked`: o segundo é "4G cortado por
                // QUALQUER motivo" (inclusive a regra do WiFi) e fazia este toggle
                // aparecer ligado com o bloqueio manual desligado — divergindo da tela
                // do carro. O estado agregado fica no card de cima, com o motivo.
                comandoRow("Bloquear o 4G agora",
                           sub: flag("mobileManualBlock", false)
                                ? "bloqueio manual ligado"
                                : (quatroG ? "4G liberado" : "4G cortado por outra regra"),
                           ligado: flag("mobileManualBlock", false), chave: "setMobileBlock") { novo in
                    await mandar("setMobileBlock", valor: novo)
                }
                Divider().background(DS.border)
                comandoRow("Controle de dados (master)",
                           sub: "Sem ele as regras abaixo não cortam nada",
                           ligado: flag("mobileControlEnabled", (u["controle4g"] as? Bool) == true),
                           chave: "setMobileControl") { novo in
                    await mandar("setMobileControl", valor: novo)
                }
                Divider().background(DS.border)
                comandoRow("Cortar 4G no WiFi",
                           sub: "Quando a tela está numa rede WiFi",
                           ligado: flag("mobileBlockOnWifi", false), chave: "setBlockOnWifi") { novo in
                    await mandar("setBlockOnWifi", valor: novo)
                }
                Divider().background(DS.border)
                comandoRow("Cortar 4G no Android Auto / CarPlay",
                           sub: "Projeção usa os dados do celular",
                           ligado: flag("mobileBlockOnProjection", false), chave: "setBlockOnProjection") { novo in
                    await mandar("setBlockOnProjection", valor: novo)
                }
                Divider().background(DS.border)
                comandoRow("Cortar 4G por consumo",
                           sub: limiteTexto, ligado: flag("mobileAutoblock", false),
                           chave: "setAutoblock") { novo in
                    await mandar("setAutoblock", valor: novo)
                }
                limiteRow
                Divider().background(DS.border)
                comandoRow("Prioridade automática de WiFi",
                           sub: "Troca sozinho pela rede preferida",
                           ligado: flag("wifiPriorityEnabled", (u["wifiPrioridade"] as? Bool) == true),
                           chave: "setWifiPriority") { novo in
                    await mandar("setWifiPriority", valor: novo)
                }
            }
        }
    }

    private var limiteTexto: String {
        let mb = (snap["mobileLimitMb"] as? Int) ?? 0
        let dia = (snap["mobileCycleDay"] as? Int) ?? 0
        if mb <= 0 { return "Limite não informado" }
        let g = Double(mb) / 1024
        return "Limite \(g >= 1 ? String(format: "%.0f GB", g) : "\(mb) MB")"
            + (dia > 0 ? " · renova dia \(dia)" : "")
    }

    /// Limite e dia do ciclo só aparecem quando o corte por consumo está ligado —
    /// fora disso são números que não governam nada.
    /// Barra de 0 a 10 GB, a mesma faixa da tela do Impulse — passos de 0,5 GB.
    /// Só manda o comando quando o dedo sai do slider (`onEditingChanged`), senão
    /// cada pixel arrastado viraria um `call()` no carro.
    @ViewBuilder private var limiteRow: some View {
        if flag("mobileAutoblock", false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(limiteGbLabel).font(.system(size: DS.FontSize.micro, weight: .semibold))
                        .foregroundStyle(DS.text2)
                    Spacer()
                    if let c = consumoTexto {
                        Text(c).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.teal)
                    }
                }
                Slider(value: Binding(
                    get: { limiteGbAtual },
                    set: { limiteGbLocal = $0 }
                // Passo de 0,25 GB = 256 MB. Vai em MB pro provider, então o valor
                // quebrado chega inteiro (1,25 GB → 1280 MB).
                ), in: 0...10, step: 0.25) { editando in
                    if !editando {
                        // Manda em MB, não em GB: `gb` é Int no provider, então 1,5 GB
                        // era arredondado pra 2 e 0,5 pra 1 — o slider andava de meio
                        // em meio e o carro só recebia valores cheios.
                        let mb = Int(((limiteGbLocal ?? limiteGbAtual) * 1024).rounded())
                        Task { await mandar("setDataLimit", mb: max(0, mb)) }
                    }
                }
                .tint(DS.green)
                .frame(minHeight: 44)
            }
        }
    }

    private var limiteGbAtual: Double {
        limiteGbLocal ?? Double((snap["mobileLimitMb"] as? Int) ?? 0) / 1024
    }
    private var limiteGbLabel: String {
        let g = limiteGbAtual
        if g <= 0 { return "Limite: sem teto" }
        let mb = Int((g * 1024).rounded())
        // Abaixo de 1 GB mostra em MB ("512 MB" lê melhor que "0,5 GB"). Acima, só
        // usa decimal quando o valor não é GB cheio — com passo de 256 MB aparecem
        // valores como 1,25 GB, e "1,3 GB" (uma casa) mentiria sobre o que foi pedido.
        if mb < 1024 { return "Limite: \(mb) MB" }
        if mb % 1024 == 0 { return "Limite: \(mb / 1024) GB" }
        return "Limite: " + String(format: "%.2f", g).replacingOccurrences(of: ".", with: ",") + " GB"
    }

    private func comandoRow(_ titulo: String, sub: String, ligado: Bool, chave: String,
                            acao: @escaping (Bool) async -> Void) -> some View {
        // Otimista com reconciliação: o toggle vai pro valor pedido na hora e um
        // spinner mostra que está confirmando. Quando o snapshot chega, `pendentes`
        // é limpo e o valor exibido volta a ser o do CARRO — se o Impulse recusou,
        // o toggle volta sozinho, que é a informação honesta.
        let pendente = pendentes[chave]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(.system(size: DS.FontSize.body, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(pendente != nil ? "confirmando no carro…" : sub)
                    .font(.system(size: DS.FontSize.micro))
                    .foregroundStyle(pendente != nil ? DS.teal : DS.muted)
            }
            Spacer()
            if pendente != nil { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { pendente ?? ligado }, set: { novo in
                pendentes[chave] = novo
                Task {
                    await acao(novo)
                    await esperarConfirmacao(chave)
                }
            }))
            .labelsHidden()
            .tint(DS.green)
            .disabled(pendente != nil)
        }
        .frame(minHeight: 44)
    }

    /// Solta o valor pendente quando o carro responde — ou desiste após 10s, pra o
    /// toggle não ficar travado se o carro estiver dormindo.
    private func esperarConfirmacao(_ chave: String) async {
        let antes = (store.raw["uplink_cmd"] as? [String: Any])?["ts"] as? Double ?? 0
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let agora = (store.raw["uplink_cmd"] as? [String: Any])?["ts"] as? Double ?? 0
            if agora > antes { pendentes[chave] = nil; return }
        }
        pendentes[chave] = nil
        if erro == nil { erro = "O carro não confirmou. Ele pode estar dormindo — o valor mostrado é o último conhecido." }
    }

    // MARK: redes salvas

    private var redesCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("REDES SALVAS NO CARRO").font(.system(size: DS.FontSize.micro, weight: .bold))
                        .foregroundStyle(DS.muted).tracking(1)
                    Spacer()
                    Button {
                        Task { await listar() }
                    } label: {
                        Text(buscandoRedes ? "Buscando…" : "Buscar")
                            .font(.system(size: DS.FontSize.micro, weight: .semibold))
                            .foregroundStyle(DS.green)
                            .padding(.horizontal, 10).frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(buscandoRedes)
                }
                if redes.isEmpty {
                    Text("Toque em Buscar para listar as redes que o carro já conhece. Só é possível conectar em rede salva — cadastrar rede nova tem que ser na tela do carro.")
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                } else {
                    ForEach(redes, id: \.self) { ssid in
                        Button {
                            Task { await mandar("connectWifi", ssid: ssid) }
                        } label: {
                            HStack {
                                Image(systemName: "wifi").font(.system(size: 12)).foregroundStyle(DS.teal)
                                Text(ssid).font(.system(size: DS.FontSize.body)).foregroundStyle(DS.text)
                                Spacer()
                                if enviando == "connectWifi:" + ssid { ProgressView().controlSize(.small) }
                                else { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(DS.muted) }
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // O switch é assíncrono no Impulse — o WiFi pisca ~10s.
                    Text("A troca leva ~10 s e o WiFi oscila nesse intervalo.")
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                }
            }
        }
    }

    // MARK: redes visíveis (scanWifi)

    private var visiveisCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("REDES POR PERTO").font(.system(size: DS.FontSize.micro, weight: .bold))
                        .foregroundStyle(DS.muted).tracking(1)
                    Spacer()
                    Button { Task { await escanear() } } label: {
                        Text(escaneando ? "Procurando…" : "Procurar")
                            .font(.system(size: DS.FontSize.micro, weight: .semibold))
                            .foregroundStyle(DS.green)
                            .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(escaneando)
                }
                if visiveis.isEmpty {
                    Text("Mostra o que o carro enxerga agora, com sinal. Conectar só funciona em rede já salva — as outras precisam ser cadastradas primeiro.")
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                } else {
                    ForEach(visiveis, id: \.ssid) { r in
                        let salva = redes.contains(r.ssid)
                        // Rede não salva não tem ação: cadastrar remotamente não
                        // funciona neste head unit (o Android devolve sucesso e a rede
                        // não persiste), então oferecer o botão era prometer o que não
                        // se entrega. Cadastra-se uma vez na tela do carro e depois o
                        // "conectar" remoto funciona.
                        Button {
                            if salva { Task { await mandar("connectWifi", ssid: r.ssid) } }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: barras(r.nivel)).font(.system(size: 12))
                                    .foregroundStyle(r.nivel > -70 ? DS.green : DS.orange)
                                if r.seg { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(DS.muted) }
                                Text(r.ssid).font(.system(size: DS.FontSize.body)).foregroundStyle(DS.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(salva ? "salva" : "não salva")
                                    .font(.system(size: DS.FontSize.micro))
                                    .foregroundStyle(salva ? DS.green : DS.muted)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!salva)
                    }
                    Text("Rede \"não salva\" precisa ser cadastrada uma vez na tela do carro — depois dá pra conectar daqui.")
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                }
            }
        }
    }

    private func barras(_ nivel: Int) -> String {
        // dBm: > -60 forte, > -70 bom, abaixo fraco.
        if nivel > -60 { return "wifi" }
        if nivel > -70 { return "wifi.exclamationmark" }
        return "wifi.slash"
    }

    // MARK: rádio WiFi (destrutivo)

    private var wifiRadioCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("RÁDIO WIFI DO CARRO").font(.system(size: DS.FontSize.micro, weight: .bold))
                    .foregroundStyle(DS.muted).tracking(1)
                Text("Desligar o WiFi corta o acesso remoto se o carro não tiver 4G disponível — inclusive este app. Só faça com 4G de reserva ou estando perto do carro.")
                    .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                HStack(spacing: 10) {
                    Button { avisoWifiOff = true } label: {
                        Text("Desligar WiFi")
                            .font(.system(size: DS.FontSize.micro, weight: .semibold))
                            .foregroundStyle(DS.red)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(DS.red.opacity(0.12)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { Task { await mandar("setWifiEnabled", valor: true) } } label: {
                        Text("Ligar WiFi")
                            .font(.system(size: DS.FontSize.micro, weight: .semibold))
                            .foregroundStyle(DS.green)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(DS.green.opacity(0.12)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        // Confirmação dupla: o primeiro passo explica a consequência, o segundo
        // exige a decisão. Um alerta só, com a mão no botão, é fácil de aceitar sem ler.
        .alert("Isso pode te desconectar do carro", isPresented: $avisoWifiOff) {
            Button("Cancelar", role: .cancel) { }
            Button("Entendi, continuar") { confirmaWifiOff = true }
        } message: {
            Text("Se o carro estiver usando WiFi como única internet, desligar o rádio derruba o canal remoto e você só recupera na tela do carro.")
        }
        .alert("Desligar o WiFi agora?", isPresented: $confirmaWifiOff) {
            Button("Cancelar", role: .cancel) { }
            Button("Desligar", role: .destructive) {
                Task { await mandar("setWifiEnabled", valor: false) }
            }
        } message: {
            Text("Último aviso — o comando é enviado imediatamente.")
        }
    }

    /// Re-lê o estado a cada 4s enquanto a tela está aberta. `listSavedWifi` não
    /// altera nada e devolve o snapshot completo — é o único jeito de acompanhar as
    /// regras de corte, que não existem na query do provider. Para ao sair da tela.
    private func pollEstado() async {
        while pollAtivo {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard pollAtivo, pendentes.isEmpty else { continue }   // não atropela comando em voo
            if statusTemRegras { continue }                        // já vem por query
            _ = await post(["metodo": "listSavedWifi"])
        }
    }

    private func escanear() async {
        escaneando = true
        defer { escaneando = false }
        erro = nil
        _ = await post(["metodo": "scanWifi"])
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let cmd = store.raw["uplink_cmd"] as? [String: Any],
               (cmd["metodo"] as? String) == "scanWifi",
               let nets = cmd["networks"] as? [String] {
                // "SSID|nivel|seguranca(0/1)" — o SSID pode conter "|", então corta
                // pelos DOIS últimos separadores, não pelo primeiro.
                visiveis = nets.compactMap { linha in
                    let p = linha.split(separator: "|", omittingEmptySubsequences: false)
                    guard p.count >= 3 else { return nil }
                    let seg = p[p.count - 1] == "1"
                    let nivel = Int(p[p.count - 2]) ?? -100
                    let ssid = p[0..<(p.count - 2)].joined(separator: "|")
                    return ssid.isEmpty ? nil : (ssid, nivel, seg)
                }
                if redes.isEmpty { await listar() }   // pra marcar quais já são salvas
                return
            }
        }
        erro = "O carro não respondeu ao scan. Ele pode estar dormindo."
    }

    // MARK: rede

    private func mandar(_ metodo: String, valor: Bool? = nil, ssid: String? = nil,
                       gb: Int? = nil, mb: Int? = nil, day: Int? = nil, senha: String? = nil) async {
        erro = nil
        enviando = ssid != nil ? "\(metodo):\(ssid!)" : metodo
        defer { enviando = nil }
        var corpo: [String: Any] = ["metodo": metodo]
        if let v = valor { corpo["valor"] = v }
        if let s = ssid { corpo["ssid"] = s }
        if let g = gb { corpo["gb"] = g }
        if let m = mb { corpo["mb"] = m }
        if let d = day { corpo["day"] = d }
        if let sn = senha { corpo["senha"] = sn }
        guard let r = await post(corpo) else {
            erro = "Não foi possível falar com o bridge."
            return
        }
        if (r["ok"] as? Bool) != true {
            erro = (r["error"] as? String) ?? "O comando não foi aceito."
        }
        // O 200 aqui só diz que o comando foi ENCAMINHADO. A confirmação real vem no
        // snapshot que o Impulse devolve (state.uplink_cmd), lido por `flag()` —
        // por isso os toggles refletem o resultado, não o pedido.
    }

    private func listar() async {
        buscandoRedes = true
        defer { buscandoRedes = false }
        _ = await post(["metodo": "listSavedWifi"])
        // O resultado volta por MQTT → state.uplink_cmd. Espera curta e lê de lá.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let cmd = store.raw["uplink_cmd"] as? [String: Any],
               (cmd["metodo"] as? String) == "listSavedWifi",
               let ssids = cmd["ssids"] as? [String] {
                redes = ssids
                return
            }
        }
        erro = "O carro não respondeu a tempo. Ele pode estar dormindo."
    }

    private func post(_ corpo: [String: Any]) async -> [String: Any]? {
        guard Settings.isConfigured,
              let url = URL(string: Settings.apiBase + "/api/uplink/cmd") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
        guard let (d, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    // MARK: peças

    private func linha(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
            Spacer()
            Text(v).font(.system(size: DS.FontSize.micro, weight: .semibold)).foregroundStyle(DS.text2)
        }
    }

    private func aviso(_ txt: String, cor: Color) -> some View {
        Text(txt)
            .font(.system(size: DS.FontSize.micro))
            .foregroundStyle(cor)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
