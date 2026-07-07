//  LeaveBySheet.swift
//  Planejar saída: "saio às 8h" → a bateria chega no alvo a tempo? Quando armar
//  o pré-clima pra cabine ficar pronta na partida. Consome /api/leave-by e arma
//  o pré-clima via /api/preclimat/schedule (onceAtMs).

import SwiftUI

struct LeaveByData: Decodable {
    struct Preclimat: Decodable { let fireAtMs: Double; let durationMin: Int; let temp: Double; let tooSoon: Bool }
    let departureMs, minutesUntil, soc, target, etaMin, projectedSoc, deficitPct, needKwh, powerKw: Double
    let charging, willReachTarget: Bool
    let finishAtMs: Double?
    let preclimat: Preclimat
}

// Uma viagem planejada (pré-clima único agendado via onceAtMs).
struct TripPlan: Identifiable {
    let id: String
    let onceAtMs: Double
    let departureMs: Double
    let label: String
    let temp: Double
    let duration: Int

    init?(_ r: [String: Any]) {
        let once = anyDouble(r["onceAtMs"])
        guard once > 0, (r["enabled"] as? Bool) ?? true else { return nil }
        id = (r["id"] as? String) ?? UUID().uuidString
        onceAtMs = once
        departureMs = anyDouble(r["departureMs"])
        label = (r["label"] as? String) ?? ""
        temp = anyDouble(r["temp"])
        duration = Int(anyDouble(r["duration"]))
    }
}
private func anyDouble(_ v: Any?) -> Double {
    switch v { case let d as Double: return d; case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue; case let s as String: return Double(s) ?? 0; default: return 0 }
}

@MainActor
final class LeaveByStore: ObservableObject {
    @Published var data: LeaveByData?
    @Published var loading = false
    @Published var armed = false
    @Published var error: String?
    @Published var plans: [TripPlan] = []

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func auth(_ r: inout URLRequest) {
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
    }

    func plan(at: Date, target: Int, cabin: Int, preclimatMin: Int) async {
        let atMs = Int(at.timeIntervalSince1970 * 1000)
        guard !base.isEmpty, let u = URL(string: "\(base)/api/leave-by?atMs=\(atMs)&target=\(target)&cabin=\(cabin)&preclimatMin=\(preclimatMin)") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; armed = false; defer { loading = false }
        var r = URLRequest(url: u); r.timeoutInterval = 12; auth(&r)
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha ao planejar."; return }
            data = try JSONDecoder().decode(LeaveByData.self, from: d)
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }

    func armPreclimat() async {
        guard let d = data, !base.isEmpty, let u = URL(string: "\(base)/api/preclimat/schedule") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("application/json", forHTTPHeaderField: "Content-Type"); auth(&r)
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "HH:mm"
        let label = "Saída \(f.string(from: Date(timeIntervalSince1970: d.departureMs / 1000)))"
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "onceAtMs": Int(d.preclimat.fireAtMs), "departureMs": Int(d.departureMs),
            "label": label, "temp": d.preclimat.temp,
            "duration": d.preclimat.durationMin, "enabled": true,
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            armed = (resp as? HTTPURLResponse)?.statusCode == 200
            if !armed { error = "Falha ao armar o pré-clima." }
            await loadPlans()
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }

    // Lista as viagens planejadas (schedules com onceAtMs futuro), mais cedo primeiro.
    func loadPlans() async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/preclimat") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 12; auth(&r)
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = obj["schedules"] as? [[String: Any]] else { return }
        let now = Date().timeIntervalSince1970 * 1000
        plans = arr.compactMap(TripPlan.init)
            .filter { $0.onceAtMs > now - 5 * 60_000 }   // esconde os que já dispararam
            .sorted { $0.onceAtMs < $1.onceAtMs }
    }

    func cancelPlan(_ id: String) async {
        plans.removeAll { $0.id == id }
        guard !base.isEmpty, let u = URL(string: "\(base)/api/preclimat/schedule/\(id)") else { return }
        var r = URLRequest(url: u); r.httpMethod = "DELETE"; r.timeoutInterval = 12; auth(&r)
        _ = try? await URLSession.shared.data(for: r)
    }
}

struct LeaveBySheet: View {
    @StateObject private var store = LeaveByStore()
    @StateObject private var ctx = PreclimatContextStore()
    @Environment(\.dismiss) private var dismiss
    @State private var departure = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var cabin = 24
    @State private var preclimatMin = 20
    @State private var repeatWeekdays = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    heroStepper
                    cabinStepper
                    if let d = store.data { timelineBar(d) }
                    repeatToggle
                    DSActionButton(icon: "sparkles",
                                   title: store.data == nil ? "Planejar saída \(hhmmDate(departure))" : "Programar saída \(hhmmDate(departure))",
                                   color: DS.green, busy: store.loading) {
                        Task {
                            if store.data == nil {
                                await store.plan(at: departure, target: 80, cabin: cabin, preclimatMin: preclimatMin)
                            } else {
                                await store.armPreclimat()
                            }
                        }
                    }
                    if let d = store.data { preclimatStatus(d) }
                    if let e = store.error {
                        Text(e).font(.system(size: 12)).foregroundStyle(DS.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !store.plans.isEmpty { plannedCard }
                    Text("A cabine fica pronta na partida — o pré-clima liga sozinho alguns minutos antes.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Planejar saída")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.muted) }
                }
            }
            .task { await store.loadPlans(); await ctx.load() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // Header: título + chip de contexto da cabine à direita.
    private var header: some View {
        HStack {
            Text("Saída única").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text)
            Spacer()
            if let c = ctx.cabinTempC {
                DSChip(text: "Cabine \(Fmt.dec1(c)) °C", color: ctx.cabinFresh ? DS.teal : DS.orange)
            } else if let w = ctx.weather {
                DSChip(text: "Local \(Fmt.dec1(w.tempC)) °C", color: DS.teal)
            }
        }
    }

    // Hero: horário grande com stepper ±5 min de 44px.
    private var heroStepper: some View {
        VStack(spacing: 10) {
            Text(hhmmDate(departure))
                .font(.system(size: 72, weight: .ultraLight, design: .rounded))
                .monospacedDigit().foregroundStyle(DS.text)
            HStack(spacing: 14) {
                stepBtn("minus", DS.blue) { bump(-5) }
                Text("saída").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                stepBtn("plus", DS.orange) { bump(5) }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private func stepBtn(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundStyle(color)
                .frame(width: 44, height: 44).background(DS.panel).clipShape(Circle())
                .overlay(Circle().stroke(DS.border, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func bump(_ min: Int) {
        departure = departure.addingTimeInterval(Double(min) * 60)
        if store.data != nil { store.armed = false }
    }

    // Stepper "Cabine a 22,0 °C" em pílula.
    private var cabinStepper: some View {
        HStack {
            Text("Cabine a \(Fmt.dec1(Double(cabin))) °C").font(.system(size: 13)).foregroundStyle(DS.text)
            Spacer()
            HStack(spacing: 12) {
                stepBtn("minus", DS.blue) { if cabin > 16 { cabin -= 1; store.armed = false } }
                Text("\(cabin)").font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(DS.text).frame(minWidth: 22)
                stepBtn("plus", DS.orange) { if cabin < 32 { cabin += 1; store.armed = false } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(DS.panel).clipShape(Capsule())
    }

    // Timeline RESFRIA → PRONTA → SAÍDA (barra teal→green + tick branco).
    private func timelineBar(_ d: LeaveByData) -> some View {
        let cool = hhmm(d.preclimat.fireAtMs)
        let ready = hhmm(d.departureMs)   // cabine pronta ≈ partida
        let out = hhmm(d.departureMs)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [DS.teal, DS.green], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 1).fill(Color.white)
                        .frame(width: 2, height: 12).offset(x: g.size.width - 2)
                }
            }.frame(height: 12)
            Text("RESFRIA \(cool) · PRONTA \(ready) · SAÍDA \(out)")
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // Toggle "Repetir seg–sex" (visual — schedule único não persiste repetição).
    private var repeatToggle: some View {
        Toggle(isOn: $repeatWeekdays) {
            Text("Repetir seg–sex").font(.system(size: 13)).foregroundStyle(DS.text)
        }
        .tint(DS.green)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func preclimatStatus(_ d: LeaveByData) -> some View {
        Group {
            if d.preclimat.tooSoon {
                Label("Saída perto demais — ligue o clima agora.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(DS.orange)
            } else if store.armed {
                Label("Pré-clima armado pra \(hhmm(d.preclimat.fireAtMs)) · \(Int(d.preclimat.temp))°C", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(DS.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hhmmDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // ── Viagens planejadas (pré-clima único agendado) ─────────────────────────
    private var plannedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VIAGENS PLANEJADAS").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
            VStack(spacing: 0) {
                ForEach(store.plans) { p in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label.isEmpty ? "Viagem planejada" : p.label)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                            Text("Pré-clima liga \(planHHMM(p.onceAtMs)) · \(Int(p.temp))° · \(p.duration) min")
                                .font(.system(size: 9.5)).foregroundStyle(DS.muted)
                        }
                        Spacer()
                        Button { Task { await store.cancelPlan(p.id) } } label: {
                            Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(DS.red)
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 10)
                    if p.id != store.plans.last?.id { Rectangle().fill(DS.divider).frame(height: 1) }
                }
            }
            .padding(.horizontal, 12)
            .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
    private func planHHMM(_ ms: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private func hhmm(_ ms: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
