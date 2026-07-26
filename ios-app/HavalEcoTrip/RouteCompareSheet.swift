//  RouteCompareSheet.swift
//  Comparação de trechos recorrentes. Agrupa viagens pelo par origem→destino
//  e compara energia, consumo, tempo e custo.
//
//  Dois modos de entrada:
//   · Insights → lista de todas as rotas repetidas (ranking por frequência).
//   · Card da viagem ("Comparar rota") → abre direto no detalhe daquela rota,
//     com a viagem tocada destacada contra a média histórica.
//
//  Estilo v2 (hero + panels DS).

import SwiftUI
import CoreLocation

// MARK: - Chave canônica da rota
//
// A identidade de um trecho é o par (origem, destino). Cada ponta é resolvida
// de forma independente e HÍBRIDA:
//
//  1. Local Conhecido cadastrado no bridge (startKp/endKp → knownStart/knownEnd)
//     vence sempre. É o que o dono entende por "o mesmo lugar" e é estável entre
//     viagens, independente de onde exatamente o carro parou.
//  2. Sem nome → célula de grade geográfica (~660m).
//
// Grade PURA não serve: testado com dados reais, "Casa → Limpa Gyn" virava dois
// grupos (7× e 4×) porque o ponto de chegada no estacionamento caía em células
// vizinhas. Nome PURO também não: viagem sem local cadastrado ficaria de fora.
struct RouteKey: Hashable {
    let start: String
    let end: String

    /// ~0.006° ≈ 660m em lat e ≈ 640m em lng nesta latitude (-16.7).
    private static let cell = 0.006

    private static func endpoint(_ name: String?, _ c: CLLocationCoordinate2D?) -> String? {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            // Normaliza pra "casa" == "Casa" == "CASA " e sem acento.
            let flat = n.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return "n:" + flat
        }
        if let c {
            let la = Int((c.latitude  / cell).rounded())
            let lo = Int((c.longitude / cell).rounded())
            return "g:\(la),\(lo)"
        }
        return nil
    }

    init?(_ t: Trip) {
        guard let s = RouteKey.endpoint(t.knownStart, t.startCoord),
              let e = RouteKey.endpoint(t.knownEnd,   t.endCoord) else { return nil }
        start = s; end = e
    }
}

// MARK: - Agregado de uma rota

struct RouteGroup: Identifiable {
    let id: RouteKey
    let name: String
    let trips: [Trip]

    var n: Int { trips.count }
    /// Só viagens com distância suficiente pra consumo fazer sentido.
    private var solid: [Trip] { trips.filter { $0.distKm > 0.5 } }

    var avgKm: Double   { n == 0 ? 0 : trips.reduce(0) { $0 + $1.distKm } / Double(n) }
    var avgMin: Double  { n == 0 ? 0 : trips.reduce(0) { $0 + $1.timeSec } / Double(n) / 60 }
    var avgKwh: Double  { n == 0 ? 0 : trips.reduce(0) { $0 + $1.netKwh } / Double(n) }
    var avgCons: Double {
        let v = solid.map { $0.consumo }.filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
    var avgScore: Double? {
        let v = trips.compactMap { Eco.score($0) }
        return v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count)
    }
    func avgCost(_ pKwh: Double, _ pGas: Double) -> Double {
        n == 0 ? 0 : trips.reduce(0.0) { $0 + $1.cost(pKwh, pGas) } / Double(n)
    }

    var best:  Trip? { solid.filter { $0.consumo > 0 }.min { $0.consumo < $1.consumo } }
    var worst: Trip? { solid.filter { $0.consumo > 0 }.max { $0.consumo < $1.consumo } }
    var fastest: Trip? { trips.filter { $0.timeSec > 60 }.min { $0.timeSec < $1.timeSec } }

    /// Tendência de consumo: metade recente − metade antiga (kWh/100km).
    /// Negativo = melhorando.
    var trend: Double {
        let sorted = solid.filter { $0.consumo > 0 }.sorted { $0.date < $1.date }
        guard sorted.count >= 4 else { return 0 }
        let half = sorted.count / 2
        let old = sorted.prefix(half), new = sorted.suffix(half)
        let co = old.reduce(0.0) { $0 + $1.consumo } / Double(old.count)
        let cn = new.reduce(0.0) { $0 + $1.consumo } / Double(new.count)
        return cn - co
    }

    /// Média de consumo segmentada por faixa de temperatura externa. Sem isso a
    /// comparação engana: em dia quente o AC pesa e a mesma rota "piora" sem o
    /// motorista ter feito nada diferente.
    /// Faixas: fria <24°C · amena 24–29°C · quente ≥30°C.
    var byTemp: [(label: String, cons: Double, n: Int)] {
        let buckets: [(String, ClosedRange<Double>)] = [
            ("< 24°",  -50...23.999),
            ("24–29°",  24...29.999),
            ("≥ 30°",   30...80),
        ]
        var out: [(label: String, cons: Double, n: Int)] = []
        for (label, range) in buckets {
            let v = solid.filter { t in
                guard let temp = t.outsideTemp, t.consumo > 0 else { return false }
                return range.contains(temp)
            }.map { $0.consumo }
            // 2+ amostras por faixa: com 1 a "média" é a própria viagem e engana.
            if v.count >= 2 { out.append((label, v.reduce(0, +) / Double(v.count), v.count)) }
        }
        return out
    }

    @MainActor
    static func build(from trips: [Trip], minCount: Int = 2) -> [RouteGroup] {
        var map: [RouteKey: [Trip]] = [:]
        for t in trips where t.distKm > 0.3 {
            guard let k = RouteKey(t) else { continue }
            map[k, default: []].append(t)
        }
        let loader = TripsLoader.shared
        return map.filter { $0.value.count >= minCount }
            .map { (k, v) -> RouteGroup in
                // Nome exibido: o mais frequente do grupo (nomes variam por
                // geocode; o mais repetido é o mais representativo).
                var counts: [String: Int] = [:]
                for t in v { counts[loader.displayName(t), default: 0] += 1 }
                let name = counts.max { a, b in
                    a.value != b.value ? a.value < b.value : a.key > b.key
                }?.key ?? "Trajeto"
                return RouteGroup(id: k, name: name, trips: v.sorted { $0.date > $1.date })
            }
            .sorted { $0.n > $1.n }
    }
}

// MARK: - Sheet

struct RouteCompareSheet: View {
    /// Viagens do período ativo na tela que abriu a sheet.
    let trips: [Trip]
    var priceKwh: Double = 0
    var priceGas: Double = 0
    var kmPerLGas: Double = 0
    /// Quando vem do card de uma viagem: abre direto no detalhe da rota dela e
    /// destaca essa viagem contra a média.
    var focusTrip: Trip? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loader = TripsLoader.shared
    /// Escopo do agrupamento: período filtrado (default) × histórico completo.
    /// Ao abrir de uma viagem específica começa em "tudo" — comparar contra 2
    /// viagens do mês não diz nada; a média histórica sim.
    @State private var scopeAll: Bool
    @State private var selectedKey: RouteKey?

    init(trips: [Trip], priceKwh: Double = 0, priceGas: Double = 0, kmPerLGas: Double = 0, focusTrip: Trip? = nil) {
        self.trips = trips
        self.priceKwh = priceKwh
        self.priceGas = priceGas
        self.kmPerLGas = kmPerLGas
        self.focusTrip = focusTrip
        _scopeAll = State(initialValue: focusTrip != nil)
        _selectedKey = State(initialValue: focusTrip.flatMap { RouteKey($0) })
    }

    private var gasL: Double { priceGas > 0 ? priceGas : 6.0 }
    private var baselineKmL: Double { kmPerLGas > 1 ? kmPerLGas : 11 }

    private var source: [Trip] { scopeAll ? loader.trips : trips }
    private var groups: [RouteGroup] { RouteGroup.build(from: source) }
    /// No detalhe aceita rota com 1 registro só (a própria viagem) — a lista
    /// exige 2+, mas quem chega pelo card quer ver mesmo que seja a 1ª vez.
    private var selected: RouteGroup? {
        guard let k = selectedKey else { return nil }
        if let g = groups.first(where: { $0.id == k }) { return g }
        return RouteGroup.build(from: source, minCount: 1).first { $0.id == k }
    }
    private var totalRepeats: Int { groups.reduce(0) { $0 + $1.n } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeToggle
                    if let g = selected {
                        detail(g)
                    } else if groups.isEmpty {
                        emptyCard
                    } else {
                        hero
                        ForEach(groups) { g in
                            Button { selectedKey = g.id } label: { groupCard(g) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle(selected == nil ? "Comparar trechos" : "Trecho")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Volta pra lista quando veio de uma rota escolhida na própria
                // sheet; se entrou direto por uma viagem, não há lista atrás.
                if selected != nil && focusTrip == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { selectedKey = nil } label: {
                            Label("Rotas", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: escopo

    private var scopeToggle: some View {
        HStack(spacing: 8) {
            ForEach([false, true], id: \.self) { all in
                Button { scopeAll = all } label: {
                    Text(all ? "Histórico completo" : "Só no período")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(scopeAll == all ? DS.green : DS.text2)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(scopeAll == all ? DS.green.opacity(0.10) : DS.panel2, in: Capsule())
                        .overlay(Capsule().stroke(scopeAll == all ? DS.green.opacity(0.5) : .clear, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: lista

    private var hero: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(groups.count)")
                    .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(DS.teal)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("trechos repetidos").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(totalRepeats) viagens").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
                Text("no total").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("TRECHOS RECORRENTES")
            Text(scopeAll
                 ? "Ainda não há trechos repetidos (precisa de 2+ viagens no mesmo origem→destino)."
                 : "Nenhum trecho repetido no período. Tenta o histórico completo.")
                .font(.system(size: 12)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    @ViewBuilder private func groupCard(_ g: RouteGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                Spacer(minLength: 8)
                Text("\(g.n)×").font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(DS.teal)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
            }
            HStack(spacing: 12) {
                metric(Fmt.km(g.avgKm), "km méd.", DS.blue)
                metric("\(Int(g.avgMin.rounded())) min", "tempo méd.", DS.text)
                metric(Fmt.dec1(g.avgCons), "kWh/100", DS.green)
                if abs(g.trend) >= 0.5 {
                    trendCell(better: g.trend < 0, value: Fmt.dec1(abs(g.trend)))
                }
            }
            costRow(g)
        }
        .modifier(V2Panel())
    }

    // MARK: detalhe da rota

    @ViewBuilder private func detail(_ g: RouteGroup) -> some View {
        // Cabeçalho
        VStack(alignment: .leading, spacing: 4) {
            Text(g.name).font(.system(size: 19, weight: .bold)).foregroundStyle(DS.text).lineLimit(3)
            Text("\(g.n) \(g.n == 1 ? "viagem" : "viagens") · \(scopeAll ? "histórico completo" : "no período")")
                .font(.system(size: 11.5)).foregroundStyle(DS.text2)
        }

        // Esta viagem vs média (só quando entrou por um card)
        if let ft = focusTrip, g.n >= 2 { thisVsAvg(ft, g) }

        // Médias da rota
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("MÉDIA DO TRECHO")
            HStack(spacing: 12) {
                metric(Fmt.km(g.avgKm), "km", DS.blue)
                metric("\(Int(g.avgMin.rounded())) min", "tempo", DS.text)
                metric(Fmt.dec1(g.avgKwh), "kWh", DS.teal)
            }
            HStack(spacing: 12) {
                metric(Fmt.dec1(g.avgCons), "kWh/100", DS.green)
                metric(Fmt.brl(g.avgCost(priceKwh, gasL)), "custo", DS.text)
                if let s = g.avgScore { metric("\(Int(s.rounded()))", "score", s >= 80 ? DS.green : DS.yellow) }
            }
            costRow(g)
        }
        .modifier(V2Panel())

        // Melhor / pior / mais rápida
        if g.n >= 2 { recordsCard(g) }

        // Consumo por faixa de temperatura
        let bt = g.byTemp
        if bt.count >= 2 { tempCard(bt) }

        // Todas as viagens do trecho
        tripsList(g)
    }

    @ViewBuilder private func thisVsAvg(_ t: Trip, _ g: RouteGroup) -> some View {
        // Média SEM a viagem focada — comparar contra uma média que a inclui
        // dilui o próprio desvio que queremos mostrar.
        let others = g.trips.filter { $0.id != t.id }
        let ref = RouteGroup(id: g.id, name: g.name, trips: others)
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("ESTA VIAGEM VS MÉDIA (\(others.count)×)")
            HStack(spacing: 12) {
                deltaCell("CONSUMO", t.consumo, ref.avgCons, Fmt.dec1, "kWh/100", lowerIsBetter: true)
                deltaCell("TEMPO", t.timeSec / 60, ref.avgMin, { "\(Int($0.rounded()))" }, "min", lowerIsBetter: true)
            }
            HStack(spacing: 12) {
                deltaCell("ENERGIA", t.netKwh, ref.avgKwh, Fmt.dec1, "kWh", lowerIsBetter: true)
                deltaCell("CUSTO", t.cost(priceKwh, gasL), ref.avgCost(priceKwh, gasL), { Fmt.brl($0) }, "", lowerIsBetter: true)
            }
            if let s = Eco.score(t), let avg = ref.avgScore {
                HStack(spacing: 12) {
                    deltaCell("SCORE", Double(s), avg, { "\(Int($0.rounded()))" }, "", lowerIsBetter: false)
                    deltaCell("DISTÂNCIA", t.distKm, ref.avgKm, Fmt.km, "km", lowerIsBetter: false, neutral: true)
                }
            }
        }
        .modifier(V2Panel())
    }

    /// Célula "valor · delta% vs média". `lowerIsBetter` inverte a cor (consumo
    /// menor é bom); `neutral` desliga a cor (distância não é boa nem ruim).
    private func deltaCell(_ label: String, _ value: Double, _ avg: Double,
                           _ fmt: (Double) -> String, _ unit: String,
                           lowerIsBetter: Bool, neutral: Bool = false) -> some View {
        let pct = avg > 0.001 ? (value - avg) / avg * 100 : 0
        let better = lowerIsBetter ? pct < 0 : pct > 0
        let tint: Color = (neutral || abs(pct) < 1.5) ? DS.text2 : (better ? DS.green : DS.orange)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value > 0 ? fmt(value) : "—")
                    .font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(.system(size: 9)).foregroundStyle(DS.muted) }
            }
            if avg > 0.001 && value > 0 {
                HStack(spacing: 2) {
                    if !neutral && abs(pct) >= 1.5 {
                        Image(systemName: pct < 0 ? "arrow.down" : "arrow.up").font(.system(size: 8, weight: .bold))
                    }
                    Text("\(pct >= 0 ? "+" : "")\(Fmt.dec1(pct))% vs méd.")
                        .font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(tint)
            } else {
                Text("sem média").font(.system(size: 9.5)).foregroundStyle(DS.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func recordsCard(_ g: RouteGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("RECORDES DO TRECHO")
            if let b = g.best   { recordLine("Menor consumo", b, Fmt.dec1(b.consumo) + " kWh/100", DS.green) }
            if let w = g.worst  { recordLine("Maior consumo", w, Fmt.dec1(w.consumo) + " kWh/100", DS.orange) }
            if let f = g.fastest { recordLine("Mais rápida", f, "\(Int((f.timeSec / 60).rounded())) min", DS.blue) }
        }
        .modifier(V2Panel())
    }

    private func recordLine(_ title: String, _ t: Trip, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text)
                Text(Self.dayFmt.string(from: t.date)).font(.system(size: 10.5)).foregroundStyle(DS.muted)
            }
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(tint)
        }
    }

    @ViewBuilder private func tempCard(_ bt: [(label: String, cons: Double, n: Int)]) -> some View {
        let maxC = bt.map { $0.cons }.max() ?? 1
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("CONSUMO POR TEMPERATURA EXTERNA")
            ForEach(bt, id: \.label) { b in
                HStack(spacing: 10) {
                    Text(b.label).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.panel2)
                            Capsule().fill(LinearGradient(colors: [DS.teal, DS.orange], startPoint: .leading, endPoint: .trailing))
                                .frame(width: maxC > 0 ? geo.size.width * (b.cons / maxC) : 0)
                        }
                    }
                    .frame(height: 8)
                    Text(Fmt.dec1(b.cons)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(DS.text).frame(width: 34, alignment: .trailing)
                    Text("\(b.n)×").font(.system(size: 10)).foregroundStyle(DS.muted).frame(width: 22, alignment: .trailing)
                }
            }
            Text("AC pesa no consumo — compare dentro da mesma faixa.")
                .font(.system(size: 10)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    @ViewBuilder private func tripsList(_ g: RouteGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("VIAGENS DESTE TRECHO")
            ForEach(g.trips) { t in
                let isFocus = focusTrip?.id == t.id
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(Self.dayFmt.string(from: t.date))
                                .font(.system(size: 12, weight: isFocus ? .bold : .semibold))
                                .foregroundStyle(isFocus ? DS.green : DS.text)
                            if isFocus {
                                Text("ESTA").font(.system(size: 8, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(DS.green)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(DS.green.opacity(0.12), in: Capsule())
                            }
                        }
                        Text("\(Fmt.km(t.distKm)) km · \(Int((t.timeSec / 60).rounded())) min\(t.outsideTemp.map { " · \(Fmt.int($0))°" } ?? "")")
                            .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                    }
                    Spacer(minLength: 8)
                    Text(t.consumo > 0 ? Fmt.dec1(t.consumo) : "—")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(DS.teal)
                    Text("kWh/100").font(.system(size: 8.5)).foregroundStyle(DS.muted)
                }
                .padding(.vertical, 5)
                if t.id != g.trips.last?.id { Rectangle().fill(DS.divider).frame(height: 1) }
            }
        }
        .modifier(V2Panel())
    }

    // Custo médio real (kWh + combustível) vs se o mesmo trecho rodasse 100%
    // gasolina (km / baseline km·L × R$/L). savedPct = quanto o híbrido economiza.
    @ViewBuilder private func costRow(_ g: RouteGroup) -> some View {
        // Sem preço de energia configurado o custo real sai 0 e a economia
        // apareceria como "−100%", que é falso. Nesse caso omite a linha.
        if priceKwh > 0 {
            let real = g.trips.reduce(0.0) { $0 + $1.netKwh * priceKwh + $1.fuelL * gasL } / Double(max(g.n, 1))
            let gas  = g.trips.reduce(0.0) { $0 + ($1.distKm / baselineKmL) * gasL } / Double(max(g.n, 1))
            let savedPct = gas > 0.01 ? Int(((gas - real) / gas * 100).rounded()) : 0
            Rectangle().fill(DS.divider).frame(height: 1)
            HStack(spacing: 12) {
                metric(Fmt.brl(real), "custo méd.", DS.text)
                metric(Fmt.brl(gas), "se gasolina", DS.orange)
                if savedPct != 0 {
                    let saving = savedPct > 0
                    VStack(alignment: .leading, spacing: 3) {
                        Image(systemName: saving ? "leaf.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(saving ? DS.green : DS.orange).font(.system(size: 13))
                        Text("\(saving ? "−" : "+")\(abs(savedPct))%")
                            .font(.system(size: 18, weight: .bold)).monospacedDigit()
                            .foregroundStyle(saving ? DS.green : DS.orange)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func metric(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(v).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendCell(better: Bool, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: better ? "arrow.down.right" : "arrow.up.right")
                .foregroundStyle(better ? DS.green : DS.orange).font(.system(size: 13))
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit()
                .foregroundStyle(better ? DS.green : DS.orange)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM · HH:mm"; return f
    }()
}
