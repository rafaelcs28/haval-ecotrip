//
//  PreclimaV2View.swift
//  Pré-climatização v2 — HANDOFF-gravacoes-preclima.md, frame 11c.
//  V1 (PreclimatSheet) permanece intacta; troca via flag ui_v2.
//

import SwiftUI

struct PreclimaV2View: View {
    @StateObject private var store = PreclimatStore()
    @ObservedObject private var trips = TripsLoader.shared
    @ObservedObject private var car = CarStore.shared
    @ObservedObject private var cal = CalendarPreclimatStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false
    @State private var editing: PreclimatSched?
    @State private var showAdd = false

    private var enabledCount: Int { store.scheds.filter(\.enabled).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    if store.isActive { activeCard }
                    if let n = nextDeparture {
                        hero(n)
                        timeline(n)
                    }
                    agendamentos
                    if let sug = suggestion { suggestionCard(sug) }
                    automatico
                    Text("a cabine fica pronta ~2 min antes da saída · cancela se você não sair em 15 min")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
        .background(DS.bg.ignoresSafeArea())
        .task { await store.load(); await trips.load(); cal.refreshAuth(); await cal.sync() }
        .onAppear {
            #if DEBUG
            let d = UserDefaults.standard
            if let k = d.string(forKey: "preclima_sheet") {
                d.removeObject(forKey: "preclima_sheet")
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if k == "add" { showAdd = true }
                    else if k == "edit", let s = store.scheds.first { editing = s }
                }
            }
            #endif
        }
        .sheet(item: $editing) { s in EditSchedV2(sched: s, store: store) }
        .sheet(isPresented: $showAdd) { AddSchedV2(store: store) }
        .confirmationDialog("Cancelar pré-climatização?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Cancelar pré-clima", role: .destructive) { Task { await store.cancel() } }
            Button("Voltar", role: .cancel) {}
        } message: {
            Text("Restaura o ar-condicionado ao ajuste anterior e desliga o motor (se o carro estiver parado).")
        }
    }

    // MARK: header — back ‹ Painel + chip ativa

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text("Painel").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(DS.green)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text("Pré-climatização").font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
            Spacer(minLength: 8)
            Text(enabledCount > 0 ? "\(enabledCount) ativa\(enabledCount > 1 ? "s" : "")" : "nenhuma")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(enabledCount > 0 ? DS.green : DS.muted)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background((enabledCount > 0 ? DS.green : DS.muted).opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: próxima saída

    private struct NextDep {
        let date: Date
        let sched: PreclimatSched
    }

    private func nextOccurrence(_ s: PreclimatSched) -> Date? {
        let p = s.time.split(separator: ":")
        guard let h = Int(p.first ?? ""), let m = Int(p.last ?? "") else { return nil }
        let c = Calendar.current
        for off in 0..<8 {
            guard let day = c.date(byAdding: .day, value: off, to: Date()),
                  let d = c.date(bySettingHour: h, minute: m, second: 0, of: day), d > Date() else { continue }
            let wd = c.component(.weekday, from: d)
            switch s.recurrence {
            case "weekdays": if (2...6).contains(wd) { return d }
            case "weekends": if wd == 1 || wd == 7 { return d }
            default: return d
            }
        }
        return nil
    }

    private var nextDeparture: NextDep? {
        store.scheds.filter(\.enabled)
            .compactMap { s in nextOccurrence(s).map { NextDep(date: $0, sched: s) } }
            .min { $0.date < $1.date }
    }

    private func relDay(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "hoje" }
        if c.isDateInTomorrow(d) { return "amanhã" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    private func recLabel(_ r: String) -> String {
        switch r {
        case "daily": return "todo dia"
        case "weekends": return "sáb–dom"
        case "once": return "uma vez"
        default: return "seg–sex"
        }
    }

    private func f1(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    private func hero(_ n: NextDep) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PRÓXIMA SAÍDA")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1.2)
                Text(n.sched.time)
                    .font(.system(size: 64, weight: .ultraLight))
                    .tracking(-2).monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(recLabel(n.sched.recurrence)) · cabine a \(f1(n.sched.temp)) °C")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.green)
                Text(relDay(n.date))
                    .font(.system(size: 11.5)).foregroundStyle(DS.muted)
            }
        }
    }

    // MARK: linha do tempo (resfriar → pronta → saída)

    private func timeline(_ n: NextDep) -> some View {
        let cool = Calendar.current.date(byAdding: .minute, value: -n.sched.leadMin, to: n.date) ?? n.date
        let ready = Calendar.current.date(byAdding: .minute, value: -2, to: n.date) ?? n.date
        let hm: (Date) -> String = { d in
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
        }
        return VStack(spacing: 7) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(
                        LinearGradient(colors: [DS.teal, DS.green], startPoint: .leading, endPoint: .trailing))
                    RoundedRectangle(cornerRadius: 1).fill(.white)
                        .frame(width: 2.5, height: 14)
                        .offset(x: g.size.width * 0.86)
                }
            }
            .frame(height: 8)
            HStack {
                micro("COMEÇA A RESFRIAR \(hm(cool))", DS.teal)
                Spacer()
                micro("PRONTA \(hm(ready))", DS.text)
                Spacer()
                micro("SAÍDA \(n.sched.time)", DS.muted)
            }
        }
    }

    private func micro(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 8.5, weight: .bold)).foregroundStyle(c).tracking(0.6)
    }

    // MARK: pré-clima em andamento

    private func phaseLabel(_ p: String) -> String {
        switch p {
        case "scheduled": return "Agendada — começa em breve"
        case "starting":  return "Ligando o motor…"
        case "engine_on": return "Motor ligado"
        case "cooling":   return "Climatizando"
        default:          return "Em andamento"
        }
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                BreatheDot(color: DS.teal)
                Text("PRÉ-CLIMA ATIVA")
                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(DS.teal).tracking(1.1)
            }
            Text(store.statusDetail.isEmpty ? phaseLabel(store.statusPhase) : store.statusDetail)
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text)
            Button { showCancelConfirm = true } label: {
                HStack(spacing: 6) {
                    if store.cancelling { ProgressView().tint(.white) }
                    else { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
                    Text(store.cancelling ? "Cancelando…" : "Cancelar agora")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity).frame(height: 40)
                .foregroundStyle(.white)
                .background(DS.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(store.cancelling)
        }
        .padding(14)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(DS.teal.opacity(0.3), lineWidth: 1))
    }

    // MARK: agendamentos

    private var agendamentos: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AGENDAMENTOS")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1.2)
            VStack(spacing: 0) {
                ForEach(store.scheds) { s in
                    schedRow(s)
                    Divider().overlay(DS.divider)
                }
                Button { showAdd = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.green)
                            .frame(width: 26, height: 26)
                            .background(DS.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Adicionar agendamento")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.green)
                        Spacer()
                    }
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func schedRow(_ s: PreclimatSched) -> some View {
        let readyLabel: String = {
            let p = s.time.split(separator: ":")
            guard let h = Int(p.first ?? ""), let m = Int(p.last ?? "") else { return "" }
            let total = h * 60 + m - 2
            return String(format: "%02d:%02d", (total + 1440) % 1440 / 60, (total + 1440) % 1440 % 60)
        }()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(s.time) · \(recLabel(s.recurrence))")
                    .font(.system(size: 13.5, weight: .bold)).foregroundStyle(DS.text)
                Text(s.enabled ? "cabine a \(f1(s.temp)) °C · pronta às \(readyLabel)"
                               : "cabine a \(f1(s.temp)) °C · desativada")
                    .font(.system(size: 11)).foregroundStyle(DS.text2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { s.enabled },
                set: { v in
                    if let i = store.scheds.firstIndex(where: { $0.id == s.id }) { store.scheds[i].enabled = v }
                    Task { await store.update(s.id, "enabled", v) }
                }))
                .labelsHidden().tint(DS.green)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .opacity(s.enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { editing = s }
        .contextMenu {
            Button { editing = s } label: { Label("Editar", systemImage: "pencil") }
            Button(role: .destructive) { Task { await store.remove(s.id) } } label: {
                Label("Excluir", systemImage: "trash")
            }
        }
    }

    // MARK: sugestão inteligente (rotina + temperatura)

    private struct Routine { let dep: Int; let recurrence: String }
    private func medianDeparture(_ weekdays: Set<Int>) -> (mins: Int, count: Int)? {
        let c = Calendar.current
        let mins = trips.trips.compactMap { t -> Int? in
            let wd = c.component(.weekday, from: t.date)
            guard weekdays.contains(wd) else { return nil }
            let h = c.component(.hour, from: t.date), m = c.component(.minute, from: t.date)
            guard h >= 4 && h <= 12 else { return nil }
            return h * 60 + m
        }
        guard mins.count >= 4 else { return nil }
        let s = mins.sorted(); return (s[s.count / 2], s.count)
    }
    private var routine: Routine? {
        let weekday = medianDeparture([2, 3, 4, 5, 6])
        let weekend = medianDeparture([1, 7])
        if let wd = weekday {
            if let we = weekend, abs(wd.mins - we.mins) <= 45 {
                return Routine(dep: (wd.mins + we.mins) / 2, recurrence: "daily")
            }
            return Routine(dep: wd.mins, recurrence: "weekdays")
        }
        if let we = weekend { return Routine(dep: we.mins, recurrence: "weekends") }
        return nil
    }

    private var suggestion: (time: String, temp: Double, recurrence: String, why: String)? {
        guard store.scheds.isEmpty, !store.loading, let r = routine else { return nil }
        let t = car.outsideTemp
        let pick: (Double, String)?
        if t >= 27 { pick = (22, "Faz \(Int(t)) °C lá fora — vale esfriar a cabine antes de sair.") }
        else if t > 0 && t <= 15 { pick = (23, "Faz \(Int(t)) °C lá fora — vale aquecer a cabine antes de sair.") }
        else { pick = nil }
        guard let (target, why) = pick else { return nil }
        let pre = max(0, r.dep - 12)
        return (String(format: "%02d:%02d", pre / 60, pre % 60), target, r.recurrence,
                "\(why) Você costuma sair de manhã \(sugRecLabel(r.recurrence)).")
    }
    private func sugRecLabel(_ r: String) -> String {
        switch r {
        case "daily": return "todo dia"
        case "weekends": return "no fim de semana"
        default: return "nos dias úteis"
        }
    }

    private func suggestionCard(_ s: (time: String, temp: Double, recurrence: String, why: String)) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(DS.teal)
                Text("Sugestão inteligente")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.teal)
            }
            Text(s.why).font(.system(size: 11.5)).foregroundStyle(DS.text2)
            Button { Task { await store.addAt(time: s.time, temp: s.temp, recurrence: s.recurrence) } } label: {
                Text("+ Agendar \(s.time) · \(Int(s.temp))° · \(sugRecLabel(s.recurrence))")
                    .font(.system(size: 12.5, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .foregroundStyle(DS.teal)
                    .background(DS.teal.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.teal.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(DS.teal.opacity(0.3), lineWidth: 1))
    }

    // MARK: automático (calendário)

    private var automatico: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AUTOMÁTICO")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1.2)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pré-clima por agenda")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                        Text("antes de cada compromisso do calendário")
                            .font(.system(size: 11)).foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { cal.enabled }, set: { cal.setEnabled($0) }))
                        .labelsHidden().tint(DS.green)
                }
                if cal.enabled && !cal.authorized {
                    Button { Task { await cal.requestAccess() } } label: {
                        Label("Permitir acesso ao Calendário", systemImage: "lock.open.fill")
                            .font(.system(size: 12.5, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .foregroundStyle(.black)
                            .background(DS.teal, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if cal.enabled, let ev = cal.nextEvent {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ev.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                        HStack(spacing: 12) {
                            if let dep = cal.departure { calInfo("figure.walk", "sair ~\(hhmm(dep))") }
                            if let fire = cal.fireAt { calInfo("fan.fill", "liga \(hhmm(fire))") }
                        }
                    }
                } else if cal.enabled {
                    Text(cal.busy ? "Buscando próximo compromisso…" : "Nenhum compromisso com horário nas próximas 24h.")
                        .font(.system(size: 11.5)).foregroundStyle(DS.muted)
                }
            }
            .padding(13)
            .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private func calInfo(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(DS.muted)
            Text(text).font(.system(size: 11.5)).foregroundStyle(DS.text2)
        }
    }
}

// MARK: - stepper pill (− azul / valor teal / + laranja)

struct StepperPillV2: View {
    let value: String
    let dec: () -> Void
    let inc: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: dec) {
                Image(systemName: "minus").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.blue)
                    .frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(value)
                .font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(DS.teal)
                .frame(minWidth: 56)
            Button(action: inc) {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.orange)
                    .frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(DS.bg, in: Capsule())
        .overlay(Capsule().stroke(DS.border, lineWidth: 1))
    }
}

private let recOptsV2: [(String, String)] = [
    ("once", "Uma vez"), ("daily", "Diário"), ("weekdays", "Dias úteis"), ("weekends", "Fim de semana")
]

private func timeBind(_ time: Binding<String>, onSet: @escaping (String) -> Void) -> Binding<Date> {
    Binding(get: {
        let p = time.wrappedValue.split(separator: ":"); var c = DateComponents()
        c.hour = Int(p.first ?? "7") ?? 7; c.minute = Int(p.last ?? "30") ?? 30
        return Calendar.current.date(from: c) ?? Date()
    }, set: { d in
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let s = String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 30)
        time.wrappedValue = s
        onSet(s)
    })
}

// MARK: - criação (hora, dias, temperatura)

private struct AddSchedV2: View {
    let store: PreclimatStore
    @Environment(\.dismiss) private var dismiss
    @State private var time = "07:30"
    @State private var recurrence = "weekdays"
    @State private var temp: Double = 22
    @State private var duration: Int = 20
    @State private var saving = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Novo agendamento").font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
                Spacer()
                Button { dismiss() } label: {
                    Text("Fechar").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.muted)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("Saída").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                Spacer()
                DatePicker("", selection: timeBind($time) { _ in }, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            DSChoiceRow(options: recOptsV2, selected: recurrence, color: DS.teal) { recurrence = $0 }
            HStack {
                Text("Temperatura").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                Spacer()
                StepperPillV2(value: String(format: "%.1f°", temp).replacingOccurrences(of: ".", with: ","),
                              dec: { temp = max(16, temp - 0.5) }, inc: { temp = min(32, temp + 0.5) })
            }
            HStack {
                Text("Duração").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                Spacer()
                StepperPillV2(value: "\(duration) min",
                              dec: { duration = max(5, duration - 5) }, inc: { duration = min(60, duration + 5) })
            }
            Button {
                guard !saving else { return }
                saving = true
                Task { await store.addAt(time: time, temp: temp, recurrence: recurrence, duration: duration); dismiss() }
            } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().tint(.black) }
                    Text("Adicionar").font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity).frame(height: 46)
                .foregroundStyle(.black)
                .background(DS.green, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(DS.panel.ignoresSafeArea())
        .presentationDetents([.fraction(0.52)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - edição (hora, dias, temp, ventilador, duração, excluir)

private struct EditSchedV2: View {
    let sched: PreclimatSched
    let store: PreclimatStore
    @Environment(\.dismiss) private var dismiss
    @State private var time: String
    @State private var recurrence: String
    @State private var temp: Double
    @State private var fan: Int
    @State private var duration: Int

    init(sched: PreclimatSched, store: PreclimatStore) {
        self.sched = sched; self.store = store
        _time = State(initialValue: sched.time)
        _recurrence = State(initialValue: sched.recurrence)
        _temp = State(initialValue: sched.temp)
        _fan = State(initialValue: sched.fan)
        _duration = State(initialValue: sched.duration)
    }

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("Editar agendamento").font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
                Spacer()
                Button { dismiss() } label: {
                    Text("Fechar").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.muted)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("Saída").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                Spacer()
                DatePicker("", selection: timeBind($time) { s in Task { await store.update(sched.id, "time", s) } },
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            DSChoiceRow(options: recOptsV2, selected: recurrence, color: DS.teal) { v in
                recurrence = v; Task { await store.update(sched.id, "recurrence", v) }
            }
            stepRow("Temperatura", String(format: "%.1f°", temp).replacingOccurrences(of: ".", with: ","),
                    dec: { temp = max(16, temp - 0.5); commit("temp", temp) },
                    inc: { temp = min(32, temp + 0.5); commit("temp", temp) })
            stepRow("Ventilador", "\(fan)/7",
                    dec: { fan = max(1, fan - 1); commit("fan", fan) },
                    inc: { fan = min(7, fan + 1); commit("fan", fan) })
            stepRow("Duração", "\(duration) min",
                    dec: { duration = max(5, duration - 5); commit("duration", duration) },
                    inc: { duration = min(60, duration + 5); commit("duration", duration) })
            Button {
                Task { await store.remove(sched.id) }
                dismiss()
            } label: {
                Label("Excluir agendamento", systemImage: "trash")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(DS.red)
                    .background(DS.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(DS.panel.ignoresSafeArea())
        .presentationDetents([.fraction(0.62)])
        .presentationDragIndicator(.visible)
        .onDisappear { Task { await store.load() } }
    }

    private func commit(_ field: String, _ v: Any) {
        Task { await store.update(sched.id, field, v) }
    }

    private func stepRow(_ label: String, _ value: String, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
            Spacer()
            StepperPillV2(value: value, dec: dec, inc: inc)
        }
    }
}
