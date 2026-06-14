//  LiveRouteBanner.swift
//  Banner de rota ativa (multi-parada) no Painel — espelha o que o bridge publica
//  em state.arrival. Mostra próxima parada + destino + SOC na chegada e permite
//  PULAR a próxima parada durante o trajeto (POST /api/route/skip-stop), com prompt
//  proativo a ≤2 km da parada e botão de Desfazer (janela de 5 min).

import SwiftUI

private func anyNum(_ v: Any?) -> Double {
    switch v {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}

// Uma perna restante da rota ativa (já vem cumulativa do bridge).
private struct LiveLeg: Identifiable {
    let id = UUID()
    let name: String
    let distKm: Double
    let etaClock: String
    let socArrival: Int
    let onFuel: Bool
    let fuelL: Double
    let isFinal: Bool
}

struct LiveRouteBanner: View {
    @ObservedObject private var store = CarStore.shared
    @State private var busy = false
    @State private var confirmSkip = false

    private var arrival: [String: Any]? { store.arrivalRaw }

    private var legs: [LiveLeg] {
        guard let a = arrival, let raw = a["legs"] as? [[String: Any]] else { return [] }
        return raw.map { l in
            LiveLeg(name: (l["name"] as? String) ?? "",
                    distKm: anyNum(l["distKm"]),
                    etaClock: (l["etaClock"] as? String) ?? "",
                    socArrival: Int(anyNum(l["socArrival"])),
                    onFuel: (l["onFuel"] as? Bool) ?? false,
                    fuelL: anyNum(l["fuelL"]),
                    isFinal: (l["isFinal"] as? Bool) ?? false)
        }
    }

    // Próxima parada = 1ª perna não-final ainda à frente. nil = só falta o destino.
    private var nextStop: LiveLeg? { legs.first { !$0.isFinal } }
    private var finalLeg: LiveLeg? { legs.last }
    private var nearNext: Bool { (nextStop?.distKm ?? .infinity) <= 2 }

    // Desfazer: parada pulada/concluída dentro da janela.
    private var undoName: String? { (arrival?["undo"] as? [String: Any])?["name"] as? String }
    private var undoSkipped: Bool { ((arrival?["undo"] as? [String: Any])?["skipped"] as? Bool) ?? false }

    var body: some View {
        if arrival != nil, let fin = finalLeg, !legs.isEmpty {
            DSCard(title: "Em rota", icon: "location.fill.viewfinder") {
                VStack(alignment: .leading, spacing: 10) {
                    // Destino + ETA + SOC na chegada.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fin.name).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text).lineLimit(1)
                            Text("Chegada \(fin.etaClock) · \(Fmt.km(fin.distKm)) km")
                                .font(.caption2).foregroundStyle(DS.muted)
                        }
                        Spacer(minLength: 0)
                        if fin.onFuel {
                            HStack(spacing: 3) {
                                Image(systemName: "fuelpump.fill").font(.caption)
                                Text("\(Fmt.dec1(fin.fuelL)) L").font(.system(size: 18, weight: .bold, design: .rounded))
                            }.foregroundStyle(DS.orange)
                        } else {
                            Text("\(fin.socArrival)%").font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(arrivalSocColor(fin.socArrival))
                        }
                    }

                    // Próxima parada (quando há) + controle de pular.
                    if let ns = nextStop {
                        Divider().background(DS.border)
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.circle.fill").font(.subheadline).foregroundStyle(DS.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Próxima parada").font(.caption2).foregroundStyle(DS.muted)
                                Text(ns.name).font(.subheadline).foregroundStyle(DS.text).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text("\(Fmt.km(ns.distKm)) km").font(.caption).foregroundStyle(DS.muted)
                        }

                        // A ≤2 km: prompt proativo destacado. Senão, botão discreto.
                        if nearNext {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("A ~\(Fmt.km(ns.distKm)) km de \(ns.name). Não precisa parar?")
                                    .font(.caption).foregroundStyle(DS.text)
                                DSActionButton(icon: "arrow.uturn.right", title: "Pular \(ns.name) e ir direto",
                                               color: DS.orange, busy: busy) { skip() }
                            }
                            .padding(10)
                            .background(DS.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            Button { confirmSkip = true } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.uturn.right").font(.caption)
                                    Text("Pular esta parada").font(.caption.weight(.semibold))
                                }.foregroundStyle(DS.orange).frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .confirmationDialog("Pular \(ns.name)?", isPresented: $confirmSkip, titleVisibility: .visible) {
                                Button("Pular e seguir") { skip() }
                                Button("Cancelar", role: .cancel) {}
                            } message: { Text("Vai direto pra \(fin.name).") }
                        }
                    }

                    // Desfazer (parada pulada ou concluída dentro da janela de 5 min).
                    if let un = undoName {
                        Divider().background(DS.border)
                        HStack(spacing: 8) {
                            Image(systemName: undoSkipped ? "arrow.uturn.right" : "checkmark.circle.fill")
                                .font(.subheadline).foregroundStyle(DS.muted)
                            Text(undoSkipped ? "\(un) pulada" : "\(un) concluída")
                                .font(.caption).foregroundStyle(DS.muted).strikethrough(undoSkipped)
                            Spacer(minLength: 0)
                            Button { undo() } label: {
                                Text("Desfazer").font(.caption.weight(.semibold)).foregroundStyle(DS.teal)
                            }.disabled(busy)
                        }
                    }
                }
            }
        }
    }

    private func skip() {
        guard !busy else { return }
        busy = true
        Task {
            _ = await store.skipStop()
            busy = false
        }
    }

    private func undo() {
        guard !busy else { return }
        busy = true
        Task {
            _ = await store.routeUndo()
            busy = false
        }
    }
}
