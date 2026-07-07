//
//  PeriodFilter.swift
//  Filtro de período compartilhado por Recargas e Viagens: Hoje · 7 dias ·
//  30 dias · menu de meses (do 1º registro até hoje) · Personalizado (intervalo).
//

import SwiftUI

// kind: 0 hoje · 1 7 dias · 2 30 dias · 3 mês (monthOffset) · 4 personalizado
enum PeriodUtil {
    static func contains(kind: Int, monthOffset: Int, from: Date, to: Date, _ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch kind {
        case 0: return cal.isDateInToday(date)
        case 1: return date >= now.addingTimeInterval(-7 * 86400)
        case 2: return date >= now.addingTimeInterval(-30 * 86400)
        case 3:
            let d = cal.date(byAdding: .month, value: -monthOffset, to: now) ?? now
            return cal.isDate(date, equalTo: d, toGranularity: .month)
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
struct PeriodCalendarCard: View {
    @Binding var from: Date
    @Binding var to: Date
    var body: some View {
        VStack(spacing: 10) {
            DatePicker("De", selection: $from, displayedComponents: .date)
            DatePicker("Até", selection: $to, in: from..., displayedComponents: .date)
        }
        .font(.system(size: 14)).foregroundStyle(DS.text).tint(DS.green)
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .padding(14).background(DS.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(DS.border, lineWidth: 1))
    }
}
