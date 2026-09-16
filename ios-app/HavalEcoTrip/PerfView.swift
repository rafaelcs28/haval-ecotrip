//
//  PerfView.swift
//  Medidor de CPU/RAM do app do CARRO, ligado sob demanda.
//
//  Serve pra decidir com dado, não com palpite, se vale mover a leitura do CAN pro
//  Impulse "por performance". Fica desligado por padrão: medidor que roda sempre é
//  ele mesmo um custo.
//
//  Importante: mede o processo do EcoTrip. Um app não pode ler o /proc de outro no
//  Android 8+, então o número do Impulse só o próprio Impulse pode expor.
//
import SwiftUI

struct PerfView: View {
    @State private var ativo = false
    @State private var resumo: [String: Any] = [:]
    @State private var erro: String?
    @State private var tick = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controle
                if (resumo["amostras"] as? Int ?? 0) > 0 { veredito; numeros }
                if !procs.isEmpty { tabelaProcs }
                explicacao
                if let e = erro { avisoBox(e) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(DS.bg.ignoresSafeArea())
        .navigationTitle("Medir desempenho")
        .task { await ler() }
        .task(id: tick) {
            // Enquanto medindo, atualiza o resumo a cada 3s.
            while ativo {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await ler()
            }
        }
    }

    private var controle: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ativo ? "Medindo…" : "Parado")
                            .font(.system(size: DS.FontSize.strong, weight: .semibold))
                            .foregroundStyle(ativo ? DS.green : DS.text)
                        Text(subtitulo).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    Button {
                        Task { await alternar() }
                    } label: {
                        Image(systemName: ativo ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(DS.bg)
                            .frame(width: 56, height: 56)
                            .background(ativo ? DS.orange : DS.green)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var subtitulo: String {
        let n = resumo["amostras"] as? Int ?? 0
        let s = resumo["duracaoS"] as? Int ?? 0
        if n == 0 { return "Toque em play e use o carro normalmente" }
        let min = s / 60
        return "\(n) amostra\(n == 1 ? "" : "s") · \(min > 0 ? "\(min) min" : "\(s) s")"
            + ((resumo["versaoApk"] as? String).map { " · APK \($0)" } ?? "")
    }

    /// Conclusão em uma frase, antes dos números. Quem abre a tela quer saber "está
    /// bom ou ruim, e por causa de quem" — não interpretar seis métricas.
    private var veredito: some View {
        let meuCpu = d("cpuPctMedia") ?? 0
        let sysCpu = d("sysCpuPctMedia") ?? 0
        let load = d("load1Pico") ?? 0
        let nCores = (resumo["nCores"] as? Int) ?? 8
        let saturado = sysCpu > 60 || load > Double(nCores)
        let nossaCulpa = meuCpu > 15
        let (txt, cor): (String, Color) =
            saturado && nossaCulpa ? ("Head unit saturado e o EcoTrip contribui", DS.red)
            : saturado ? ("Head unit saturado — mas não é o EcoTrip", DS.orange)
            : nossaCulpa ? ("Folgado no geral, mas o EcoTrip está pesado", DS.orange)
            : ("Tudo folgado", DS.green)
        return DSCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(cor).frame(width: 10, height: 10)
                    Text(txt).font(.system(size: DS.FontSize.strong, weight: .semibold))
                        .foregroundStyle(DS.text)
                }
                Text(explicaVeredito(meuCpu: meuCpu, sysCpu: sysCpu, load: load, nCores: nCores))
                    .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
            }
        }
    }

    private func explicaVeredito(meuCpu: Double, sysCpu: Double, load: Double, nCores: Int) -> String {
        var partes: [String] = []
        partes.append(String(format: "EcoTrip %.1f%% de um núcleo", meuCpu))
        if sysCpu > 0 { partes.append(String(format: "sistema %.0f%%", sysCpu)) }
        // Load acima do nº de núcleos = há processo esperando CPU. É o dado que
        // explica morte de processo melhor que CPU%.
        if load > 0 {
            partes.append(String(format: "load %.1f em %d núcleos%@", load, nCores,
                                 load > Double(nCores) ? " (há fila)" : ""))
        }
        return partes.joined(separator: " · ")
    }

    private var procs: [[String: Any]] {
        (resumo["procs"] as? [[String: Any]]) ?? []
    }

    /// Tabela por app, em barras. Barra comunica proporção de relance; número em
    /// coluna exige comparar mentalmente linha por linha.
    private var tabelaProcs: some View {
        let maxRss = procs.compactMap { $0["rssMbMedia"] as? Double ?? ($0["rssMbMedia"] as? Int).map(Double.init) }.max() ?? 1
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("POR APP").font(.system(size: DS.FontSize.micro, weight: .bold))
                        .foregroundStyle(DS.muted).tracking(1)
                    Spacer()
                    if let t = resumo["totalProcs"] as? Int {
                        Text("\(procs.count) de \(t)").font(.system(size: DS.FontSize.micro))
                            .foregroundStyle(DS.muted)
                    }
                }
                ForEach(procs.indices, id: \.self) { i in
                    linhaProc(procs[i], maxRss: maxRss)
                }
                // O contrato é explícito e a diferença importa: RSS superconta páginas
                // compartilhadas (a soma passa da RAM física) e o CPU aqui é % do
                // SISTEMA, não de um núcleo como o do EcoTrip acima.
                Text(rodapeEscala).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
            }
        }
    }

    private var rodapeEscala: String {
        let kind = (resumo["memKind"] as? String) ?? "rss"
        let n = (resumo["nCores"] as? Int) ?? 8
        return (kind == "rss"
                ? "Memória em RSS: superconta páginas compartilhadas, então a soma passa da RAM física. Serve pra ranking e tendência, não pra somar. "
                : "Memória em PSS. ")
             + "CPU aqui é % do sistema (\(n) núcleos) — o número do EcoTrip acima é % de UM núcleo. Escalas diferentes."
    }

    private func linhaProc(_ p: [String: Any], maxRss: Double) -> some View {
        let nome = (p["pkg"] as? String) ?? "?"
        let rss = (p["rssMbMedia"] as? Double) ?? Double((p["rssMbMedia"] as? Int) ?? 0)
        let cpu = (p["cpuPctMedia"] as? Double) ?? Double((p["cpuPctMedia"] as? Int) ?? 0)
        let state = (p["state"] as? String) ?? ""
        let nosso = nome.contains("ecotrip")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(nomeCurto(nome))
                    .font(.system(size: DS.FontSize.micro, weight: nosso ? .bold : .regular))
                    .foregroundStyle(nosso ? DS.green : DS.text)
                    .lineLimit(1)
                if !state.isEmpty {
                    Text(state).font(.system(size: 9))
                        .foregroundStyle(state == "cached" ? DS.muted : DS.text2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DS.panel2).clipShape(Capsule())
                }
                Spacer()
                Text(String(format: "%.0f MB", rss))
                    .font(.system(size: DS.FontSize.micro, weight: .semibold))
                    .monospacedDigit().foregroundStyle(nosso ? DS.green : DS.text2)
                if cpu > 0 {
                    Text(String(format: "· %.0f%%", cpu))
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.orange)
                }
            }
            GeometryReader { g in
                Capsule().fill(nosso ? DS.green : DS.teal.opacity(0.5))
                    .frame(width: max(2, g.size.width * CGFloat(rss / max(1, maxRss))), height: 5)
            }
            .frame(height: 5)
        }
        .padding(.vertical, 2)
    }

    /// `cached` do sistema tem nome longo e prefixo repetido; o que importa é a cauda.
    private func nomeCurto(_ p: String) -> String {
        if p.count <= 28 { return p }
        let partes = p.split(separator: ".")
        return partes.count > 2 ? "…" + partes.suffix(2).joined(separator: ".") : String(p.suffix(28))
    }

    private var numeros: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("APP DO CARRO (ECOTRIP)").font(.system(size: DS.FontSize.micro, weight: .bold))
                    .foregroundStyle(DS.muted).tracking(1)
                // Média E pico: a média sozinha esconde picos que travam a interface;
                // o pico sozinho não diz se é constante ou pontual.
                par("CPU", d("cpuPctMedia"), d("cpuPctPico"), "%", DS.orange)
                Divider().background(DS.border)
                par("RAM (PSS)", d("pssMbMedia"), d("pssMbPico"), "MB", DS.teal)
                Divider().background(DS.border)
                par("Heap Java", d("heapMbMedia"), d("heapMbPico"), "MB", DS.blue)
                if let t2 = resumo["ramTotalMb"] as? Double {
                    Divider().background(DS.border)
                    Text("ANDROID INTEIRO").font(.system(size: DS.FontSize.micro, weight: .bold))
                        .foregroundStyle(DS.muted).tracking(1).padding(.top, 4)
                    par("CPU do sistema", d("sysCpuPctMedia"), d("sysCpuPctPico"), "%", DS.orange)
                    Divider().background(DS.border)
                    HStack(alignment: .firstTextBaseline) {
                        Text("RAM usada").font(.system(size: DS.FontSize.body)).foregroundStyle(DS.text)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f de %.0f MB", d("ramUsadaMbMedia") ?? 0, t2))
                                .font(.system(size: DS.FontSize.strong, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(DS.teal)
                            Text(d("ramLivreMbMin").map { String(format: "livre mín %.0f MB", $0) } ?? "")
                                .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                        }
                    }
                    if let lm = resumo["lowMemoryAmostras"] as? Int, lm > 0 {
                        // Pressão de memória é o gatilho de morte de processo que
                        // derrubou viagem e recarga — merece destaque, não uma linha.
                        avisoBox("O sistema reportou pouca memória em \(lm) amostra(s). É o gatilho que mata o app no meio da viagem.")
                    }
                    if let l = d("load1Pico") {
                        HStack {
                            Text("Load (1 min, pico)").font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                            Spacer()
                            Text(String(format: "%.2f", l)).font(.system(size: DS.FontSize.micro, weight: .semibold))
                                .monospacedDigit().foregroundStyle(DS.text2)
                        }
                    }
                }
                if let imp = d("impulseRamMbMedia") {
                    Divider().background(DS.border)
                    Text("HAVAL IMPULSE").font(.system(size: DS.FontSize.micro, weight: .bold))
                        .foregroundStyle(DS.muted).tracking(1).padding(.top, 4)
                    par("RAM do Impulse", imp, d("impulseRamMbPico"), "MB", DS.blue)
                    // Comparação direta: é a conta que decide se mover a leitura do CAN
                    // pra lá economiza no total ou só troca de bolso.
                    if let meu = d("pssMbMedia") {
                        HStack {
                            Text("EcoTrip vs Impulse").font(.system(size: DS.FontSize.micro))
                                .foregroundStyle(DS.muted)
                            Spacer()
                            Text(String(format: "%.0f MB vs %.0f MB", meu, imp))
                                .font(.system(size: DS.FontSize.micro, weight: .semibold))
                                .monospacedDigit().foregroundStyle(DS.text2)
                        }
                    }
                    if let ic = d("impCpuPctMedia"), let meuSys = d("sysCpuPctMedia"),
                       abs(ic - meuSys) > 15 {
                        // Duas contas do MESMO número divergindo muito é sinal de erro
                        // em uma delas — melhor saber que ignorar.
                        avisoBox(String(format: "CPU do sistema: %.0f%% pela minha leitura, %.0f%% pela do Impulse. Divergência grande — uma das contas está errada.", meuSys, ic))
                    }
                }
                if let t = resumo["threadsPico"] as? Double {
                    Divider().background(DS.border)
                    HStack {
                        Text("Threads (pico)").font(.system(size: DS.FontSize.body)).foregroundStyle(DS.text)
                        Spacer()
                        Text("\(Int(t))").font(.system(size: DS.FontSize.body, weight: .semibold))
                            .monospacedDigit().foregroundStyle(DS.text2)
                    }
                }
            }
        }
    }

    private func d(_ k: String) -> Double? { resumo[k] as? Double }

    private func par(_ titulo: String, _ media: Double?, _ pico: Double?,
                     _ unidade: String, _ cor: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titulo).font(.system(size: DS.FontSize.body)).foregroundStyle(DS.text)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(media.map { String(format: "%.1f \(unidade)", $0) } ?? "—")
                    .font(.system(size: DS.FontSize.strong, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(cor)
                Text(pico.map { String(format: "pico %.1f", $0) } ?? "")
                    .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
            }
        }
    }

    private var explicacao: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("COMO LER").font(.system(size: DS.FontSize.micro, weight: .bold))
                    .foregroundStyle(DS.muted).tracking(1)
                linha("CPU é % de UM núcleo. O head unit tem vários, então 25% significa um quarto de um núcleo — não do aparelho.")
                linha("PSS é a memória proporcional: não conta bibliotecas compartilhadas várias vezes. É o número honesto pra comparar processos.")
                linha("Meça durante uma viagem real. Com o carro parado o app faz muito menos, e o número não representa o uso.")
                linha("O bloco \"Android inteiro\" é o aparelho todo: dá régua pro número do app e mostra se o gargalo somos nós ou o head unit.")
                linha("A RAM do Impulse vem dele (resourceUsage, vc7284+) — no Android um app não lê o /proc do outro, então esse número só ele pode dar.")
            }
        }
    }

    private func linha(_ t: String) -> some View {
        Text("• " + t).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.text2)
    }

    private func avisoBox(_ t: String) -> some View {
        Text(t).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.red)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: rede

    private func alternar() async {
        erro = nil
        let novo = !ativo
        guard let url = URL(string: Settings.apiBase + "/api/perf") else { return }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ativo": novo])
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (o["ok"] as? Bool) == true else {
            erro = "Não foi possível falar com o bridge."
            return
        }
        ativo = novo
        tick.toggle()
        await ler()
    }

    private func ler() async {
        guard let url = URL(string: Settings.apiBase + "/api/perf") else { return }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        resumo = o
        // O bridge é a fonte do estado: se o carro dormiu no meio, `ativo` volta a
        // false sozinho e o botão acompanha, em vez de mentir "medindo".
        if let a = o["ativo"] as? Bool { ativo = a }
    }
}
