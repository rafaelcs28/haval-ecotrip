//
//  MaintenanceSheet.swift
//  Popup único de Revisão: resumo, próximas, histórico (excluir) e registrar.
//  Importa tudo do PWA (/api/maintenance).
//

import SwiftUI
import UserNotifications

struct MaintenanceSheet: View {
    @ObservedObject var store: MaintenanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAdd = false
    @State private var newType = ""
    @State private var newOdo = ""
    @State private var newDate = Date()
    @State private var newCost = ""
    @State private var newNotes = ""
    @State private var reminderSet = false

    // Menor distância restante entre as próximas manutenções (hero "até a revisão").
    private var kmUntilService: Double? {
        store.items.compactMap { $0.remaining_km }.filter { $0 > 0 }.min()
    }
    // Estimativa de semanas com base na média diária de km.
    private var weeksUntilService: Int? {
        guard let km = kmUntilService, store.dailyKmAvg > 0 else { return nil }
        return max(1, Int((km / store.dailyKmAvg / 7).rounded()))
    }

    private static let grp: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f }()
    private func miles(_ v: Double) -> String { Self.grp.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v) }
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM yyyy"; return f }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    heroCard
                    // Próximas
                    if !store.items.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(store.items.enumerated()), id: \.element.id) { i, m in
                                HStack(spacing: 10) {
                                    Circle().fill(m.statusColor).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.label ?? "Manutenção").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                                        Text(whenText(m)).font(.system(size: 9.5)).foregroundStyle(DS.muted)
                                    }
                                    Spacer()
                                    if let nk = m.next_km, nk > 0 { Text("aos \(miles(nk)) km").font(.system(size: 9.5)).foregroundStyle(DS.muted) }
                                }
                                .padding(.vertical, 11)
                                if i != store.items.count - 1 { Rectangle().fill(DS.divider).frame(height: 1) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }

                    // Lembrete local (agendar revisão) — não integra concessionária.
                    DSActionButton(icon: "bell.badge", title: "Lembrar de agendar revisão", color: DS.green) {
                        scheduleReminder()
                    }
                    if reminderSet {
                        Label("Lembrete salvo no Calendário", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(DS.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Registrar
                    DSCard {
                        DisclosureGroup(isExpanded: $showAdd) {
                            VStack(spacing: 12) {
                                if !store.intervals.isEmpty {
                                    Picker("Tipo", selection: $newType) {
                                        ForEach(store.intervals) { it in Text(it.label ?? it.id).tag(it.id) }
                                    }.pickerStyle(.menu).tint(DS.green)
                                }
                                field("Hodômetro (km)", text: $newOdo, keyboard: .numberPad)
                                DatePicker("Data", selection: $newDate, displayedComponents: .date)
                                    .font(.system(size: 14)).foregroundStyle(DS.text)
                                field("Custo (R$)", text: $newCost, keyboard: .decimalPad)
                                field("Notas", text: $newNotes, keyboard: .default)
                                Button {
                                    let odo = Double(newOdo.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")) ?? 0
                                    let cost = Double(newCost.replacingOccurrences(of: ",", with: "."))
                                    guard odo > 0, !newType.isEmpty else { return }
                                    Task {
                                        await store.add(typeId: newType, odometer: odo, dateMs: newDate.timeIntervalSince1970 * 1000, cost: cost, notes: newNotes)
                                        newOdo = ""; newCost = ""; newNotes = ""; showAdd = false
                                    }
                                } label: {
                                    Text("Registrar").font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 46)
                                        .foregroundStyle(.black).background(DS.green).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }.padding(.top, 8)
                        } label: {
                            Label("Registrar manutenção", systemImage: "plus.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                        }.tint(DS.green)
                    }

                    // Histórico
                    DSCard(title: "Histórico", icon: "clock.arrow.circlepath") {
                        if store.history.isEmpty {
                            Text("Sem registros.").font(.caption).foregroundStyle(DS.muted)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(store.history) { h in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(h.label ?? labelFor(h.type_id)).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                                            Text("\(h.date_ms.map { Self.df.string(from: Date(timeIntervalSince1970: $0/1000)) } ?? "—") · \(miles(h.odometer_km ?? 0)) km")
                                                .font(.caption).foregroundStyle(DS.muted)
                                            if let n = h.notes, !n.isEmpty { Text(n).font(.caption2).foregroundStyle(DS.muted.opacity(0.8)) }
                                        }
                                        Spacer()
                                        if let c = h.cost, c > 0 { Text(brl(c)).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.orange) }
                                        Button { Task { await store.removeHistory(h.id) } } label: {
                                            Image(systemName: "trash").font(.caption).foregroundStyle(DS.red)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Revisão").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.muted) }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await store.load()
            if newType.isEmpty { newType = store.intervals.first?.id ?? "" }
            if newOdo.isEmpty, store.currentOdometer > 0 { newOdo = String(Int(store.currentOdometer)) }
        }
    }

    private var header: some View {
        HStack {
            Text("Revisão").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text)
            Spacer()
            if store.currentOdometer > 0 {
                DSChip(text: "\(miles(store.currentOdometer)) km", color: DS.blue)
            }
        }
    }

    // Hero: km até a revisão + ~semanas + barra de progresso; fallback pro custo.
    private var heroCard: some View {
        let km = kmUntilService
        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(km.map { miles($0) } ?? "—")
                    .font(.system(size: 56, weight: .ultraLight, design: .rounded)).monospacedDigit().foregroundStyle(DS.text)
                Text("km").font(.system(size: 16)).foregroundStyle(DS.muted)
            }
            Text(weeksUntilService.map { "até a revisão · ~\($0) semanas" } ?? "até a próxima revisão")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.4)
            if let km, km > 0 {
                let frac = CGFloat(max(0.02, min(1, 1 - km / 10_000)))   // 10k km = ciclo típico
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.panel3).frame(height: 6)
                        Capsule().fill(DS.greenGrad).frame(width: g.size.width * frac, height: 6)
                    }
                }.frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    // Lembrete local (UserNotifications) — não integra a concessionária.
    private func scheduleReminder() {
        let c = UNMutableNotificationContent()
        c.title = "Revisão do carro"
        c.body = kmUntilService.map { "Faltam \(miles($0)) km para a próxima revisão. Agende com folga." }
            ?? "Hora de agendar a próxima revisão."
        c.sound = .default
        // Dispara em ~metade das semanas estimadas (mín. 7 dias), pra lembrar com folga.
        let days = Double(weeksUntilService ?? 4) * 7 / 2
        let secs = max(7 * 86_400, days * 86_400)
        let trig = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
        let req = UNNotificationRequest(identifier: "maint-reminder", content: c, trigger: trig)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(req)
        }
        reminderSet = true
    }

    private func whenText(_ m: MaintItem) -> String {
        if let km = m.remaining_km { return km <= 0 ? "vencida" : "faltam \(miles(km)) km" }
        if let d = m.remaining_days { return d <= 0 ? "vencida" : "faltam \(Int(d)) dias" }
        return ""
    }
    private func labelFor(_ typeId: String?) -> String {
        store.intervals.first { $0.id == typeId }?.label ?? "Manutenção"
    }
    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard).foregroundStyle(DS.text)
            .padding(10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))
    }
}
