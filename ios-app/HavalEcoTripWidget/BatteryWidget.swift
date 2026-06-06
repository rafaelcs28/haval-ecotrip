//
//  BatteryWidget.swift
//  Widget de home screen mostrando SOC, autonomia EV e combustível do Haval.
//  Atualiza via fetch direto do bridge — iOS dispara TimelineProvider.getTimeline
//  a cada ~15-30min em background. Compartilha URL+token com o app principal
//  via App Group.
//
import WidgetKit
import SwiftUI

// ── Entry ────────────────────────────────────────────────────────────────────
struct BatteryEntry: TimelineEntry {
    let date: Date
    let soc: Double            // 0-100 %
    let evKm: Double           // autonomia elétrica km
    let iceKm: Double          // autonomia térmica km
    let fuelPct: Double        // 0-100 %
    let charging: Bool
    let chargingKw: Double     // potência atual se carregando
    let remainingMin: Int      // min restantes se carregando
    // Campos extras pro Large
    let outsideTemp: Double?   // °C
    let insideTemp: Double?    // °C
    let batt12v: Double?       // 0-100 %
    let odometer: Double       // km
    let locationName: String?  // local conhecido se houver
    let priceKwh: Double?      // R$/kWh
    let priceGas: Double?      // R$/L
    let engineOn: Bool         // motor ligado
    let lockState: String?     // "locked" / "unlocked"
    let doorOpen: Bool         // alguma porta aberta
    let isConfigured: Bool     // app não configurado → widget de setup
    let error: String?
}

// ── Provider ─────────────────────────────────────────────────────────────────
struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), soc: 47, evKm: 38, iceKm: 280, fuelPct: 70,
                     charging: false, chargingKw: 0, remainingMin: 0,
                     outsideTemp: 26.5, insideTemp: 24, batt12v: 92,
                     odometer: 12453, locationName: "Goiânia, GO",
                     priceKwh: 0.59, priceGas: 6.42,
                     engineOn: false, lockState: "locked", doorOpen: false,
                     isConfigured: true, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        Task {
            let entry = await fetch()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        Task {
            let entry = await fetch()
            // Próxima atualização em 15min (iOS decide se honra ou atrasa)
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func fetch() async -> BatteryEntry {
        // Diagnóstico: deixa o widget mostrar o ESTADO do Settings em vez de
        // só "Configure o app" — facilita pegar problema de App Group.
        let urlStr = Settings.bridgeURL
        let tokLen = Settings.bridgeToken.count
        if urlStr.isEmpty && tokLen == 0 {
            return errorEntry("App Group vazio — abra o app uma vez pra migrar config")
        }
        if urlStr.isEmpty { return errorEntry("URL vazia (token len=\(tokLen))") }
        if tokLen == 0    { return errorEntry("Token vazio (url=\(urlStr.prefix(20))…)") }
        guard let url = URL(string: urlStr + "/api/state") else {
            return errorEntry("URL inválida: \(urlStr.prefix(30))")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorEntry("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            // Door open: qualquer porta lateral, traseira ou porta-malas aberta
            let doorKeys = ["door_fl", "door_fr", "door_rl", "door_rr", "door_trunk"]
            let anyDoor = doorKeys.contains { (json[$0] as? String) == "open" }
            return BatteryEntry(
                date:         Date(),
                soc:          (json["soc_pct"]              as? Double) ?? 0,
                evKm:         (json["autonomy_ev_km"]       as? Double) ?? 0,
                iceKm:        (json["autonomy_ice_km"]      as? Double) ?? 0,
                fuelPct:      ((json["fuel_l"] as? Double) ?? 0) / 0.55,    // ~55L tanque
                charging:     (json["charging_state"]       as? String) == "Carregando",
                chargingKw:   (json["charge_power_kw"]      as? Double) ?? 0,
                remainingMin: Int(((json["charge_remaining_min"] as? Double) ?? 0).rounded()),
                outsideTemp:  json["outside_temp"]          as? Double,
                insideTemp:   json["inside_temp"]           as? Double,
                batt12v:      json["batt_12v_pct"]          as? Double,
                odometer:     (json["odometer_km"]          as? Double) ?? 0,
                locationName: (json["gps_place_name"]       as? String)
                                ?? (json["car_known_place"] as? String),
                priceKwh:     (json["battery_avg_price_per_kwh"] as? Double)
                                ?? (json["price_kwh"]            as? Double),
                priceGas:     (json["tank_avg_price_per_l"] as? Double)
                                ?? (json["price_gas_per_l"] as? Double),
                engineOn:     (json["engine_state"]         as? String) == "on",
                lockState:    json["lock_state"]            as? String,
                doorOpen:     anyDoor,
                isConfigured: true,
                error:        nil
            )
        } catch {
            return errorEntry(error.localizedDescription)
        }
    }

    private func errorEntry(_ msg: String) -> BatteryEntry {
        BatteryEntry(date: Date(), soc: 0, evKm: 0, iceKm: 0, fuelPct: 0,
                     charging: false, chargingKw: 0, remainingMin: 0,
                     outsideTemp: nil, insideTemp: nil, batt12v: nil,
                     odometer: 0, locationName: nil,
                     priceKwh: nil, priceGas: nil,
                     engineOn: false, lockState: nil, doorOpen: false,
                     isConfigured: true, error: msg)
    }
}

// ── Widget View ──────────────────────────────────────────────────────────────
struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: BatteryEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:  smallView
            case .systemMedium: mediumView
            case .systemLarge:  largeView
            default:            smallView
            }
        }
        .containerBackground(for: .widget) { Color.black }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: entry.charging ? "bolt.fill" : "battery.100")
                    .foregroundStyle(entry.charging ? .green : .white)
                Spacer()
                Text("Haval")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !entry.isConfigured {
                Text("Configure o app").font(.caption).foregroundStyle(.secondary)
            } else if let err = entry.error {
                Text("⚠ \(err)").font(.caption2).foregroundStyle(.red)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(entry.soc))")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("%").font(.title3).foregroundStyle(.secondary)
                }
                if entry.charging && entry.remainingMin > 0 {
                    Text(remainingLabel)
                        .font(.caption).foregroundStyle(.green)
                } else if entry.evKm > 0 {
                    Text("⚡ \(Int(entry.evKm)) km")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("atualizado \(entry.date, style: .relative)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            // Esquerda: SOC grande
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: entry.charging ? "bolt.fill" : "battery.100")
                        .foregroundStyle(entry.charging ? .green : .white)
                    Text("Bateria").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(entry.soc))")
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("%").font(.title2).foregroundStyle(.secondary)
                }
                if entry.charging {
                    Text("\(String(format: "%.1f", entry.chargingKw)) kW · \(remainingLabel)")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            Divider().background(Color.white.opacity(0.2))
            // Direita: autonomia + combustível
            VStack(alignment: .leading, spacing: 8) {
                MetricRow(icon: "⚡", label: "EV", value: "\(Int(entry.evKm)) km", color: .green)
                MetricRow(icon: "⛽", label: "Térm.", value: "\(Int(entry.iceKm)) km", color: .orange)
                if entry.fuelPct > 0 {
                    MetricRow(icon: "🛢", label: "Tanque", value: "\(Int(min(entry.fuelPct, 100)))%", color: .yellow)
                }
                Spacer(minLength: 0)
                Text("atualizado \(entry.date, style: .relative)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var remainingLabel: String {
        let m = entry.remainingMin
        guard m > 0 else { return "—" }
        if m >= 60 {
            return "~\(m/60)h\(String(format: "%02d", m%60))"
        }
        return "~\(m) min"
    }

    // ── Large view ───────────────────────────────────────────────────────────
    private var largeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — título + status flags
            HStack(spacing: 6) {
                Image(systemName: entry.charging ? "bolt.fill" : "car.fill")
                    .foregroundStyle(entry.charging ? .green : .white)
                Text("Haval EcoTrip").font(.subheadline).bold()
                Spacer()
                statusFlags
            }
            .padding(.bottom, 8)

            // Bloco SOC + Autonomia
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(entry.soc))")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        Text("%").font(.title3).foregroundStyle(.secondary)
                    }
                    Text(entry.charging
                         ? "\(String(format: "%.1f", entry.chargingKw)) kW · \(remainingLabel)"
                         : "bateria")
                        .font(.caption2)
                        .foregroundStyle(entry.charging ? .green : .secondary)
                }
                Divider().background(Color.white.opacity(0.15))
                VStack(alignment: .leading, spacing: 6) {
                    MetricRow(icon: "⚡", label: "EV",       value: "\(Int(entry.evKm)) km",   color: .green)
                    MetricRow(icon: "⛽", label: "Térmico",  value: "\(Int(entry.iceKm)) km",  color: .orange)
                    if entry.fuelPct > 0 {
                        MetricRow(icon: "🛢", label: "Tanque",  value: "\(Int(min(entry.fuelPct, 100)))%", color: .yellow)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 8)

            // Bloco ambiente + 12V
            VStack(alignment: .leading, spacing: 6) {
                if let ext = entry.outsideTemp, let ins = entry.insideTemp {
                    LargeRow(icon: "🌡", text: "Ext \(Int(ext.rounded()))°  ·  Int \(Int(ins.rounded()))°")
                } else if let ext = entry.outsideTemp {
                    LargeRow(icon: "🌡", text: "Ext \(Int(ext.rounded()))°")
                }
                if let b12 = entry.batt12v {
                    LargeRow(icon: "🔋", text: "12V \(Int(b12))%", color: b12 < 50 ? .red : (b12 < 80 ? .yellow : .secondary))
                }
                if let loc = entry.locationName, !loc.isEmpty {
                    LargeRow(icon: "📍", text: loc)
                }
                if entry.odometer > 0 {
                    LargeRow(icon: "🛣", text: "Odômetro \(Int(entry.odometer).formatted(.number.grouping(.automatic))) km")
                }
                if let pkwh = entry.priceKwh, let pgas = entry.priceGas {
                    LargeRow(icon: "💵", text: "R$ \(String(format: "%.2f", pkwh))/kWh · R$ \(String(format: "%.2f", pgas))/L")
                }
            }

            // Botão interativo: trancar/destrancar direto do widget (iOS 17+).
            if #available(iOS 17.0, *), entry.isConfigured, entry.error == nil {
                if entry.lockState != "unlocked" {
                    Button(intent: UnlockCarIntent()) {
                        Label("Destrancar", systemImage: "lock.open.fill")
                            .font(.caption2.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange).padding(.top, 6)
                } else {
                    Button(intent: LockCarIntent()) {
                        Label("Trancar", systemImage: "lock.fill")
                            .font(.caption2.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).padding(.top, 6)
                }
            }

            Spacer(minLength: 0)
            HStack {
                if let err = entry.error {
                    Text("⚠ \(err)").font(.system(size: 9)).foregroundStyle(.red)
                } else {
                    Text("atualizado \(entry.date, style: .relative)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusFlags: some View {
        HStack(spacing: 4) {
            if entry.engineOn {
                FlagBadge(text: "ON", color: .orange)
            }
            if entry.lockState == "unlocked" {
                FlagBadge(text: "🔓", color: .yellow)
            }
            if entry.doorOpen {
                FlagBadge(text: "🚪", color: .red)
            }
        }
    }
}

struct LargeRow: View {
    let icon: String
    let text: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 8) {
            Text(icon).font(.caption)
            Text(text).font(.caption).foregroundStyle(color)
            Spacer(minLength: 0)
        }
    }
}

struct FlagBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct MetricRow: View {
    let icon: String, label: String, value: String, color: Color
    var body: some View {
        HStack(spacing: 6) {
            Text(icon).font(.caption)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.callout).bold().foregroundStyle(color)
        }
    }
}

// ── Widget Definition ────────────────────────────────────────────────────────
struct BatteryWidget: Widget {
    let kind: String = "BatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("Bateria Haval")
        .description("SOC, autonomia EV e térmica do Haval H6 PHEV.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
