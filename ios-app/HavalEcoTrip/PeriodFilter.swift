//
//  PeriodFilter.swift
//  Filtro de período compartilhado por Recargas e Viagens: Hoje · 7 dias ·
//  30 dias · menu de meses (do 1º registro até hoje) · Personalizado (intervalo).
//

import SwiftUI

// kind: 0 hoje · 1 7 dias · 2 30 dias · 3 mês (monthOffset) · 4 personalizado ·
//       5 tudo · 6 desde a última recarga · 7 desde o último abastecimento
enum PeriodUtil {
    /// kind reservado pra "sem filtro" (mostra tudo).
    static let kindAll = 5
    /// Janelas que não são data: o corte é o último evento de energia. É a
    /// pergunta que o dono faz de verdade ("quanto rendeu essa carga?"), e ela
    /// não cai em nenhum intervalo de calendário.
    static let kindSinceCharge = 6
    static let kindSinceRefuel = 7
    /// Janela ancorada em viagens escolhidas na lista: de uma, até outra, ou as
    /// duas. Nenhum intervalo de calendário responde "quanto rendeu daquela
    /// viagem do meio da manhã pra cá".
    static let kindTripRange = 8

    /// - Parameter since: data do evento de corte para os modos 6 e 7. Sem ela
    ///   esses modos não filtram nada — e devolver `true` mostraria o histórico
    ///   inteiro sob um rótulo que promete o contrário, então devolvem `false`.
    /// - Parameter until: limite superior do modo 8. Com `since` nil o corte é
    ///   só de cima, e vice-versa — marcar uma ponta só é um uso legítimo.
    static func contains(kind: Int, monthOffset: Int, from: Date, to: Date, _ date: Date,
                         now: Date = Date(), since: Date? = nil, until: Date? = nil) -> Bool {
        let cal = Calendar.current
        switch kind {
        case 0: return cal.isDateInToday(date)
        case 1: return date >= now.addingTimeInterval(-7 * 86400)
        case 2: return date >= now.addingTimeInterval(-30 * 86400)
        case 3:
            let d = cal.date(byAdding: .month, value: -monthOffset, to: now) ?? now
            return cal.isDate(date, equalTo: d, toGranularity: .month)
        case kindAll: return true            // sem filtro — tudo passa
        case kindSinceCharge, kindSinceRefuel:
            guard let since else { return false }
            return date >= since
        case kindTripRange:
            // Sem ponta nenhuma marcada não há janela — devolver tudo seria
            // mentir sobre o que o filtro diz estar fazendo.
            if since == nil && until == nil { return false }
            if let since, date < since { return false }
            if let until, date > until { return false }
            return true
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
        case kindSinceCharge: return "desde a recarga"
        case kindSinceRefuel: return "desde o abastecimento"
        case kindTripRange: return "entre viagens"
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
    /// Data da última recarga / do último abastecimento. Nil esconde o chip —
    /// oferecer "desde a recarga" sem recarga nenhuma só produz lista vazia.
    var sinceCharge: Date? = nil
    var sinceRefuel: Date? = nil
    /// Só a tela que tem a lista de viagens oferece âncora por viagem — é lá que
    /// dá pra escolher. Os closures avisam qual ponta o usuário quer marcar.
    var escolherDe: (() -> Void)? = nil
    var escolherAte: (() -> Void)? = nil
    /// Tela sem lista (Insights) que quer só ATIVAR a janela já marcada na aba
    /// Viagens. Escolher, só lá — é onde as viagens estão.
    var entreViagensPronta = false

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
                // Logo depois de "Tudo", e não no fim: dois chips largos ("Desde
                // a recarga"/"Desde o abastecimento") ficariam fora da tela, e a
                // barra já corta em ~"Personalizado" no iPhone. Um menu só, no
                // mesmo molde do de mês, cabe e diz qual está ativo.
                if sinceCharge != nil || sinceRefuel != nil || escolherDe != nil || entreViagensPronta { energiaMenu }
                chip("Hoje", 0)
                chip("7 dias", 1)
                chip("30 dias", 2)
                monthMenu
                chip("Personalizado", 4)
            }
            .padding(.vertical, 1)
        }
    }

    private func chip(_ label: String, _ k: Int, icon: String? = nil) -> some View {
        Button { kind = k } label: { pill(label, on: kind == k, icon: icon) }.buttonStyle(.plain)
    }

    private var energiaAtiva: Bool {
        kind == PeriodUtil.kindSinceCharge || kind == PeriodUtil.kindSinceRefuel
            || kind == PeriodUtil.kindTripRange
    }

    private var energiaIcone: String {
        switch kind {
        case PeriodUtil.kindSinceRefuel: return "fuelpump.fill"
        case PeriodUtil.kindTripRange:   return "flag.checkered"
        default: return "bolt.fill"
        }
    }

    private var energiaMenu: some View {
        Menu {
            if sinceCharge != nil {
                Button { kind = PeriodUtil.kindSinceCharge } label: {
                    Label("Última recarga", systemImage: "bolt.fill")
                }
            }
            if sinceRefuel != nil {
                Button { kind = PeriodUtil.kindSinceRefuel } label: {
                    Label("Último abastecimento", systemImage: "fuelpump.fill")
                }
            }
            if let escolherDe, let escolherAte {
                Divider()
                Button { escolherDe() } label: {
                    Label("Desde uma viagem…", systemImage: "flag.fill")
                }
                Button { escolherAte() } label: {
                    Label("Até uma viagem…", systemImage: "flag.checkered")
                }
            } else if entreViagensPronta {
                Divider()
                Button { kind = PeriodUtil.kindTripRange } label: {
                    Label("Entre as viagens marcadas", systemImage: "flag.checkered")
                }
            }
        } label: {
            pill(energiaAtiva ? PeriodUtil.label(kind: kind, monthOffset: 0).capitalizedFirst : "Desde…",
                 on: energiaAtiva, chevron: true, icon: energiaIcone)
        }
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

    private func pill(_ label: String, on: Bool, chevron: Bool = false, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
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

private extension String {
    /// "desde a recarga" → "Desde a recarga". Os rótulos do PeriodUtil nascem
    /// minúsculos porque vivem no meio de frase ("32 km em 30 dias").
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
