//
//  MonitorWidget.swift
//  Widget do Bridge Health. Existe por um motivo específico: o monitor era aberto
//  ~3x por dia só pra conferir que está tudo certo. Essa pergunta ("preciso agir?")
//  cabe numa olhada na tela de bloqueio — abrir a página é pro caso de precisar
//  investigar depois.
//
//  Lê /api/monitor-glance (191 bytes), não /api/health (117 KB): o iOS orça tempo
//  de execução do timeline e o widget roda em 4G.
//
//  A severidade vem PRONTA do bridge. A triagem da página web é rollup de cor no
//  cliente; recalcular aqui criaria a terceira régua pro mesmo fato — erro que
//  esta base já cometeu com temperatura de inversor e silêncio do APK.
//
import WidgetKit
import SwiftUI

// ── Entry ────────────────────────────────────────────────────────────────────
struct MonitorEntry: TimelineEntry {
    let date: Date
    let state: String          // "ok" | "warn" | "crit"
    let crit: Int
    let warn: Int
    let worstTitle: String?
    let worstSince: Date?
    let solarKw: Double
    let solarKwhToday: Double
    let plants: Int
    let carAwake: Bool
    let uptimeSec: Int
    let error: String?

    var color: Color {
        if error != nil { return LAv2.muted }
        switch state {
        case "crit": return LAv2.red
        case "warn": return LAv2.orange
        default:     return LAv2.green
        }
    }
    /// Título curto do alerta: os do bridge vêm com emoji e prefixo de planta
    /// ("☀️ Solar Catalão — coletor offline"), longo demais pra tela de bloqueio.
    var worstShort: String? {
        guard let t = worstTitle else { return nil }
        var s = t.unicodeScalars.filter { !($0.properties.isEmoji && $0.value > 0x238C) }
                 .reduce(into: "") { $0.unicodeScalars.append($1) }
        if let i = s.range(of: " — ")?.upperBound { s = String(s[i...]) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// ── Provider ─────────────────────────────────────────────────────────────────
struct MonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitorEntry {
        MonitorEntry(date: Date(), state: "ok", crit: 0, warn: 0, worstTitle: nil,
                     worstSince: nil, solarKw: 21.9, solarKwhToday: 43.5, plants: 3,
                     carAwake: false, uptimeSec: 7200, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MonitorEntry) -> Void) {
        Task { completion(await fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitorEntry>) -> Void) {
        Task {
            let e = await fetch()
            // Com algo pegando fogo vale insistir mais: 5min. Tudo ok, 20min —
            // o iOS trata isso como pedido, não promessa, e orça por app/dia.
            let next = Date().addingTimeInterval(e.state == "ok" ? 20 * 60 : 5 * 60)
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }

    private func err(_ m: String) -> MonitorEntry {
        MonitorEntry(date: Date(), state: "ok", crit: 0, warn: 0, worstTitle: nil,
                     worstSince: nil, solarKw: 0, solarKwhToday: 0, plants: 0,
                     carAwake: false, uptimeSec: 0, error: m)
    }

    private func fetch() async -> MonitorEntry {
        let base = Settings.bridgeURL
        if base.isEmpty || Settings.bridgeToken.isEmpty {
            return err("abra o app pra configurar")
        }
        guard let url = URL(string: base + "/api/monitor-glance") else { return err("URL inválida") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return err("HTTP \(code)") }
            let worst = j["worst"] as? [String: Any]
            let solar = j["solar"] as? [String: Any] ?? [:]
            let car   = j["car"]   as? [String: Any] ?? [:]
            let br    = j["bridge"] as? [String: Any] ?? [:]
            let sinceMs = worst?["since_ms"] as? Double
            return MonitorEntry(
                date: Date(),
                state: (j["state"] as? String) ?? "ok",
                crit: (j["crit"] as? Int) ?? 0,
                warn: (j["warn"] as? Int) ?? 0,
                worstTitle: worst?["title"] as? String,
                worstSince: sinceMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                solarKw: (solar["kw"] as? Double) ?? 0,
                solarKwhToday: (solar["kwh_today"] as? Double) ?? 0,
                plants: (solar["plants"] as? Int) ?? 0,
                carAwake: (car["awake"] as? Bool) ?? false,
                uptimeSec: (br["uptime_sec"] as? Int) ?? 0,
                error: nil)
        } catch {
            // Sem rede o widget mostra o problema, não um "tudo ok" inventado.
            return err("sem resposta")
        }
    }
}

// ── Peças ────────────────────────────────────────────────────────────────────
private func fmtKw(_ v: Double) -> String {
    String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
}
private func fmtUp(_ s: Int) -> String {
    if s < 3600 { return "\(s / 60)min" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

/// Frase de veredito. Fica no singular/plural certo em vez de "1 problema(s)".
private func verdict(_ e: MonitorEntry) -> String {
    if let m = e.error { return m }
    if e.crit > 0 { return e.crit == 1 ? "1 crítico" : "\(e.crit) críticos" }
    if e.warn > 0 { return e.warn == 1 ? "1 atenção" : "\(e.warn) atenções" }
    return "Tudo ok"
}

// ── Home screen ──────────────────────────────────────────────────────────────
struct MonitorSmallView: View {
    let e: MonitorEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Rectangle().fill(e.color).frame(width: 8, height: 8)
                Text("BRIDGE").font(.system(size: 9, weight: .heavy)).kerning(1.1)
                    .foregroundStyle(LAv2.muted)
                Spacer()
            }
            Text(verdict(e))
                .font(.system(size: e.error == nil ? 19 : 13, weight: .heavy))
                .foregroundStyle(e.state == "ok" && e.error == nil ? LAv2.text : e.color)
                .minimumScaleFactor(0.7).lineLimit(2).padding(.top, 6)
            if let w = e.worstShort {
                Text(w).font(.system(size: 10.5)).foregroundStyle(LAv2.text2)
                    .lineLimit(2).padding(.top, 3)
            }
            Spacer(minLength: 4)
            if e.error == nil {
                Text("\(fmtKw(e.solarKw)) kW").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LAv2.text)
                Text("\(fmtKw(e.solarKwhToday)) kWh hoje · no ar \(fmtUp(e.uptimeSec))")
                    .font(.system(size: 9)).foregroundStyle(LAv2.muted).lineLimit(1)
            }
        }
    }
}

struct MonitorMediumView: View {
    let e: MonitorEntry
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Rectangle().fill(e.color).frame(width: 8, height: 8)
                    Text("BRIDGE HEALTH").font(.system(size: 9, weight: .heavy)).kerning(1.1)
                        .foregroundStyle(LAv2.muted)
                }
                Text(verdict(e))
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(e.state == "ok" && e.error == nil ? LAv2.text : e.color)
                    .minimumScaleFactor(0.6).lineLimit(1).padding(.top, 5)
                if let w = e.worstShort {
                    Text(w).font(.system(size: 11)).foregroundStyle(LAv2.text2)
                        .lineLimit(2).padding(.top, 2)
                } else if e.error == nil {
                    Text("nada a fazer").font(.system(size: 11)).foregroundStyle(LAv2.muted)
                        .padding(.top, 2)
                }
                Spacer(minLength: 2)
                Text("atualizado \(e.date, style: .time)")
                    .font(.system(size: 9)).foregroundStyle(LAv2.muted)
            }
            if e.error == nil {
                VStack(alignment: .trailing, spacing: 7) {
                    kpi("\(fmtKw(e.solarKw)) kW", "solar agora")
                    kpi("\(fmtKw(e.solarKwhToday)) kWh", "hoje · \(e.plants) usinas")
                    kpi(fmtUp(e.uptimeSec), e.carAwake ? "no ar · carro acordado" : "no ar · carro dormindo")
                }
            }
        }
    }
    private func kpi(_ v: String, _ l: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(v).font(.system(size: 15, weight: .bold)).foregroundStyle(LAv2.text)
            Text(l).font(.system(size: 8.5)).foregroundStyle(LAv2.muted).lineLimit(1)
        }
    }
}

// ── Lock screen ──────────────────────────────────────────────────────────────
// É aqui que o widget paga o próprio custo: responde "preciso agir?" sem
// desbloquear o telefone. Família accessory renderiza monocromático tingido, então
// cor não carrega significado — o texto tem que dizer tudo.
struct MonitorAccessoryView: View {
    @Environment(\.widgetFamily) var family
    let e: MonitorEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(inlineText)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                    Text(e.crit + e.warn > 0 ? "\(e.crit + e.warn)" : "ok")
                        .font(.system(size: 11, weight: .heavy))
                }
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                    Text("BRIDGE").font(.system(size: 10, weight: .heavy)).kerning(0.8)
                }
                Text(verdict(e)).font(.system(size: 15, weight: .heavy))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(e.worstShort ?? (e.error == nil
                        ? "\(fmtKw(e.solarKw)) kW · \(fmtKw(e.solarKwhToday)) kWh hoje" : " "))
                    .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                    .widgetAccentable(false)
            }
        }
    }
    private var icon: String {
        if e.error != nil { return "wifi.slash" }
        switch e.state {
        case "crit": return "exclamationmark.triangle.fill"
        case "warn": return "exclamationmark.circle"
        default:     return "checkmark.circle"
        }
    }
    private var inlineText: String {
        if let m = e.error { return "Bridge: \(m)" }
        if e.crit + e.warn == 0 { return "Bridge ok · \(fmtKw(e.solarKw)) kW" }
        return "Bridge: \(verdict(e))"
    }
}

// ── Widgets ──────────────────────────────────────────────────────────────────
struct MonitorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MonitorWidget", provider: MonitorProvider()) { e in
            Group {
                if #available(iOS 17.0, *) {
                    content(e).containerBackground(LAv2.bg, for: .widget)
                } else {
                    content(e).padding(12).background(LAv2.bg)
                }
            }
        }
        .configurationDisplayName("Bridge Health")
        .description("Veredito do monitor, geração solar e tempo no ar.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
    @ViewBuilder private func content(_ e: MonitorEntry) -> some View {
        ViewThatFits { MonitorMediumView(e: e); MonitorSmallView(e: e) }
    }
}

struct LockMonitorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LockMonitorWidget", provider: MonitorProvider()) { e in
            MonitorAccessoryView(e: e)
        }
        .configurationDisplayName("Bridge Health (bloqueio)")
        .description("Precisa agir? Sem desbloquear o telefone.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
