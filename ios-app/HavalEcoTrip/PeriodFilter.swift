//
//  PeriodFilter.swift
//  Filtro de período compartilhado por Recargas e Viagens: Hoje · 7 dias ·
//  30 dias · menu de meses (do 1º registro até hoje) · Personalizado (intervalo).
//

import SwiftUI

// kind: 0 hoje · 1 7 dias · 2 30 dias · 3 mês (monthOffset) · 4 personalizado · 5 tudo
enum PeriodUtil {
    /// kind reservado pra "sem filtro" (mostra tudo).
    static let kindAll = 5

    static func contains(kind: Int, monthOffset: Int, from: Date, to: Date, _ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch kind {
        case 0: return cal.isDateInToday(date)
        case 1: return date >= now.addingTimeInterval(-7 * 86400)
        case 2: return date >= now.addingTimeInterval(-30 * 86400)
        case 3:
            let d = cal.date(byAdding: .month, value: -monthOffset, to: now) ?? now
            return cal.isDate(date, equalTo: d, toGranularity: .month)
        case kindAll: return true            // sem filtro — tudo passa
        default:
            let lo = cal.startOfDay(for: from)
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to)) ?? to
            return date >= lo && date < hi
        }
    }

    /// Rótulo curto pro hero ("30 dias", "Julho"…).
    static func label(kind: Int, monthOffset: Int) -> String {
        switch kind {
        case 0: return "hoje"
        case 1: return "7 dias"
        case 2: return "30 dias"
        case 3: return monthLabel(monthOffset)
        case kindAll: return "tudo"
        default: return "período"
        }
    }

    /// Offsets de mês (0 = mês atual) do mais recente até o mês do 1º registro.
    static func monthOffsets(earliest: Date?) -> [Int] {
        guard let earliest else { return Array(0..<6) }
        let cal = Calendar.current
        let a = cal.dateComponents([.year, .month], from: earliest)
        let b = cal.dateComponents([.year, .month], from: Date())
        let months = ((b.year ?? 0) - (a.year ?? 0)) * 12 + ((b.month ?? 0) - (a.month ?? 0))
        return Array(0...max(0, min(months, 120)))
    }

    static func monthLabel(_ offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .month, value: -offset, to: Date()) ?? Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "LLLL" : "LLL/yy"
        return f.string(from: d).capitalized
    }
}

struct PeriodFilterBar: View {
    @Binding var kind: Int
    @Binding var monthOffset: Int
    let earliest: Date?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "Tudo" primeiro: limpa qualquer filtro e mostra o histórico
                // inteiro. Fica no início pra estar sempre visível sem scroll
                // horizontal (a barra corta em ~"Personalizado" no iPhone).
                Button { kind = PeriodUtil.kindAll } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "infinity").font(.system(size: 10, weight: .bold))
                        Text("Tudo").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(kind == PeriodUtil.kindAll ? DS.green : DS.text2)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(kind == PeriodUtil.kindAll ? DS.green.opacity(0.10) : DS.panel2, in: Capsule())
                    .overlay(Capsule().stroke(kind == PeriodUtil.kindAll ? DS.green.opacity(0.5) : .clear, lineWidth: 1))
                }.buttonStyle(.plain)
                chip("Hoje", 0)
                chip("7 dias", 1)
                chip("30 dias", 2)
                monthMenu
                chip("Personalizado", 4)
            }
            .padding(.vertical, 1)
        }
    }

    private func chip(_ label: String, _ k: Int) -> some View {
        Button { kind = k } label: { pill(label, on: kind == k) }.buttonStyle(.plain)
    }

    private var monthMenu: some View {
        Menu {
            ForEach(PeriodUtil.monthOffsets(earliest: earliest), id: \.self) { off in
                Button(PeriodUtil.monthLabel(off)) { monthOffset = off; kind = 3 }
            }
        } label: {
            pill(kind == 3 ? PeriodUtil.monthLabel(monthOffset) : "Mês", on: kind == 3, chevron: true)
        }
    }

    private func pill(_ label: String, on: Bool, chevron: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12, weight: .bold))
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(on ? DS.green : DS.text2)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(on ? DS.green.opacity(0.10) : DS.panel2, in: Capsule())
        .overlay(Capsule().stroke(on ? DS.green.opacity(0.5) : .clear, lineWidth: 1))
    }
}

// Cartão de intervalo (De/Até) reutilizado quando kind == personalizado.
//
// ⚠ Estado LOCAL (@State), não o Binding do pai, alimenta os DatePickers.
// Motivo: as views que hospedam este card observam CarStore/TripsLoader, que
// publicam telemetria a cada poucos segundos. Cada publish reavalia o body do
// pai e recria os computed Bindings (`fromDate`/`toDate` em ViagensV2View) —
// nova identidade faz o SwiftUI descartar o DatePicker e o mês navegado no
// popover do calendário voltava sozinho pro mês da data selecionada, tornando
// impossível escolher uma data em outro mês. Com @State local o picker
// sobrevive à recomposição; escrevemos no Binding externo via onChange.
struct PeriodCalendarCard: View {
    @Binding var from: Date
    @Binding var to: Date
    @State private var localFrom: Date
    @State private var localTo: Date

    init(from: Binding<Date>, to: Binding<Date>) {
        _from = from; _to = to
        _localFrom = State(initialValue: from.wrappedValue)
        _localTo   = State(initialValue: to.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 10) {
            DatePicker("De", selection: $localFrom, displayedComponents: .date)
            DatePicker("Até", selection: $localTo, in: localFrom..., displayedComponents: .date)
        }
        .font(.system(size: 14)).foregroundStyle(DS.text).tint(DS.green)
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .padding(14).background(DS.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(DS.border, lineWidth: 1))
        .onChange(of: localFrom) { _, v in
            from = v
            if localTo < v { localTo = v; to = v }   // mantém Até >= De
        }
        .onChange(of: localTo) { _, v in to = v }
    }
}
