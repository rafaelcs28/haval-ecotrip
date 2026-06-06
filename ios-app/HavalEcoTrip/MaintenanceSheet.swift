//
//  MaintenanceSheet.swift
//  Popup único de Revisão: resumo, próximas, histórico (excluir) e registrar.
//  Importa tudo do PWA (/api/maintenance).
//

import SwiftUI

struct MaintenanceSheet: View {
    @ObservedObject var store: MaintenanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAdd = false
    @State private var newType = ""
    @State private var newOdo = ""
    @State private var newDate = Date()
    @State private var newCost = ""
    @State private var newNotes = ""

    private static let grp: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f }()
    private func miles(_ v: Double) -> String { Self.grp.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v) }
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM yyyy"; return f }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Resumo
                    DSCard {
                        HStack {
                            DSMetric(value: store.currentOdometer > 0 ? miles(store.currentOdometer) : "—", unit: "km", label: "Hodômetro")
                            DSMetric(value: store.dailyKmAvg > 0 ? String(format: "%.0f", store.dailyKmAvg) : "—", unit: "km/dia", label: "Média diária")
                            DSMetric(value: brl(store.totalCost), label: "Custo total", color: DS.orange)
                        }
                    }

                    // Próximas
                    if !store.items.isEmpty {
                        DSCard(title: "Próximas", icon: "calendar.badge.clock") {
                            VStack(spacing: 12) {
                                ForEach(store.items) { m in
                                    HStack(spacing: 8) {
                                        Circle().fill(m.statusColor).frame(width: 9, height: 9)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.label ?? "Manutenção").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                                            Text(whenText(m)).font(.caption).foregroundStyle(DS.muted)
                                        }
                                        Spacer()
                                        if let nk = m.next_km, nk > 0 { Text("aos \(miles(nk)) km").font(.caption).foregroundStyle(DS.muted) }
                                    }
                                }
                            }
                        }
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task {
            await store.load()
            if newType.isEmpty { newType = store.intervals.first?.id ?? "" }
            if newOdo.isEmpty, store.currentOdometer > 0 { newOdo = String(Int(store.currentOdometer)) }
        }
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
