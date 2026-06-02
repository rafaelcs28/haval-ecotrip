//
//  ControlSheets.swift
//  Sheets full-screen abertos pela aba Drive: Controles de condução e AC.
//  Chaves/endpoints espelham o PWA/iPad (drive-mode, power-reserve,
//  charge-soc-target, terrain-mode, steer-mode, regen-level, one-pedal, esp,
//  hvac/<control>).
//

import SwiftUI

// Grade de opções (alvo de toque grande) — para listas maiores (terreno etc.).
private struct ChoiceGrid<T: Hashable>: View {
    let options: [(T, String)]
    let selected: T
    var color: Color = DS.green
    let onPick: (T) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selected
                Button { onPick(opt.0) } label: {
                    Text(opt.1).font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .foregroundStyle(on ? .black : DS.text)
                        .background(on ? color : DS.panel2)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? .clear : DS.border, lineWidth: 1))
                }
            }
        }
    }
}

// MARK: - Controles de condução
struct DriveControlsSheet: View {
    @ObservedObject var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pendMode: Int?
    @State private var pendReserve: Int?
    @State private var pendRegen: Int?
    @State private var pendTerrain: Int?
    @State private var pendSteer: Int?
    @State private var socTarget: Double = 50
    @State private var editingSlider = false

    private var mode: Int { pendMode ?? store.intOrNil("drive_mode") ?? -1 }
    private var reserve: Int { pendReserve ?? store.powerReserve ?? -1 }
    private var regen: Int { pendRegen ?? store.intOrNil("regen_level") ?? -1 }
    private var terrain: Int { pendTerrain ?? store.terrainMode ?? -1 }
    private var steer: Int { pendSteer ?? store.steerMode ?? -1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DSCard(title: "Modo de condução", icon: "bolt.car") {
                        VStack(spacing: 12) {
                            DSChoiceRow(options: [(0, "HEV"), (1, "Prior. EV"), (3, "EV Puro")], selected: mode, color: DS.green) { v in
                                pendMode = v; Task { await store.setDriveMode(v) }
                            }
                            if mode == 0 {   // sub-modos do HEV
                                Divider().overlay(DS.border)
                                DSChoiceRow(options: [(1, "Inteligente"), (2, "Prioritário")], selected: reserve, color: DS.teal) { v in
                                    pendReserve = v; Task { await store.setPowerReserve(v) }
                                }
                                if reserve == 2 {   // alvo de SOC 20–80
                                    VStack(spacing: 4) {
                                        HStack {
                                            Text("Manter bateria em").font(.caption).foregroundStyle(DS.muted)
                                            Spacer()
                                            Text("\(Int(socTarget))%").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.teal)
                                        }
                                        Slider(value: $socTarget, in: 20...80, step: 5) { editing in
                                            editingSlider = editing
                                            if !editing { Task { await store.setChargeSocTarget(Int(socTarget)) } }
                                        }.tint(DS.teal)
                                    }
                                }
                            }
                        }
                    }

                    DSCard(title: "Regeneração", icon: "arrow.triangle.2.circlepath") {
                        DSChoiceRow(options: [(0, "Normal"), (1, "Alto"), (2, "Baixo")], selected: regen, color: DS.teal) { v in
                            pendRegen = v; Task { await store.setRegen(v) }
                        }
                    }

                    DSCard {
                        VStack(spacing: 4) {
                            toggleRow("One-Pedal", systemImage: "p.circle", isOn: store.onePedalOn) { on in
                                Task { await store.setOnePedal(on) }
                            }
                            Divider().overlay(DS.border)
                            toggleRow("ESP (estabilidade)", systemImage: "car.fill", isOn: store.espOn) { on in
                                Task { await store.setEsp(on) }
                            }
                        }
                    }

                    DSCard(title: "Modo de terreno", icon: "mountain.2.fill") {
                        ChoiceGrid(options: [(0,"Normal"),(1,"Sport"),(2,"Eco"),(3,"Neve"),(4,"Areia"),(5,"Lama"),(11,"AWD")],
                                   selected: terrain, color: DS.orange) { v in
                            pendTerrain = v; Task { await store.setTerrain(v) }
                        }
                    }

                    DSCard(title: "Direção", icon: "steeringwheel") {
                        DSChoiceRow(options: [(2, "Conforto"), (0, "Normal"), (1, "Sport")], selected: steer, color: DS.blue) { v in
                            pendSteer = v; Task { await store.setSteer(v) }
                        }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Controles").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .onAppear { if store.chargeSocTarget >= 20 { socTarget = Double(store.chargeSocTarget) } }
        .onChange(of: store.intOrNil("drive_mode")) { _, v in if v == pendMode { pendMode = nil } }
        .onChange(of: store.powerReserve) { _, v in if v == pendReserve { pendReserve = nil } }
        .onChange(of: store.intOrNil("regen_level")) { _, v in if v == pendRegen { pendRegen = nil } }
        .onChange(of: store.terrainMode) { _, v in if v == pendTerrain { pendTerrain = nil } }
        .onChange(of: store.steerMode) { _, v in if v == pendSteer { pendSteer = nil } }
        .onChange(of: store.chargeSocTarget) { _, v in if !editingSlider && v >= 20 { socTarget = Double(v) } }
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Label(title, systemImage: systemImage).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.text)
        }.tint(DS.green)
    }
}

// MARK: - Ar-condicionado (completo, com seções)
struct ACSheet: View {
    @ObservedObject var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showMore = false

    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Mestre
                    DSCard {
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: store.acOn ? "snowflake" : "power").font(.title2).foregroundStyle(store.acOn ? DS.blue : DS.muted)
                                Text(store.acOn ? "Ligado" : "Desligado").font(.headline).foregroundStyle(DS.text)
                                Spacer()
                            }
                            DSChoiceRow(options: [(true, "Ligar"), (false, "Desligar")], selected: store.acOn, color: DS.blue) { v in
                                Task { await store.setAcPower(v) }
                            }
                            HStack(spacing: 10) {
                                miniToggle("AUTO", store.autoMode) { v in Task { await store.setHvac("auto", on: v) } }
                                miniToggle("A/C", store.acEnable) { v in Task { await store.setHvac("ac_enable", on: v) } }
                                miniToggle("MAX", store.acmax) { v in Task { await store.setHvac("acmax", on: v) } }
                            }
                        }
                    }

                    // Temperatura
                    DSCard(title: "Temperatura", icon: "thermometer.medium") {
                        VStack(spacing: 12) {
                            stepperRow(label: "Motorista", value: "\(f1(store.driverTemp))°",
                                       dec: { adjustTemp("driver_temp", store.driverTemp, -0.5) },
                                       inc: { adjustTemp("driver_temp", store.driverTemp, 0.5) })
                            Divider().overlay(DS.border)
                            miniToggle("Sincronizar lados", store.syncTemp, wide: true) { v in Task { await store.setHvac("sync", on: v) } }
                            if !store.syncTemp {
                                stepperRow(label: "Passageiro", value: "\(f1(store.passengerTemp))°",
                                           dec: { adjustTemp("passenger_temp", store.passengerTemp, -0.5) },
                                           inc: { adjustTemp("passenger_temp", store.passengerTemp, 0.5) })
                            }
                        }
                    }

                    // Ventilação
                    DSCard(title: "Ventilação", icon: "wind") {
                        VStack(spacing: 12) {
                            stepperRow(label: "Velocidade", value: "\(store.fanSpeed)/7",
                                       dec: { adjustInt("fan_speed", store.fanSpeed, -1, 0, 7) },
                                       inc: { adjustInt("fan_speed", store.fanSpeed, 1, 0, 7) })
                            Divider().overlay(DS.border)
                            Text("DIREÇÃO DO FLUXO").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ChoiceGrid(options: [(0,"Frente"),(1,"Frente+Pés"),(2,"Pés"),(3,"Pés+Vidro"),(4,"Para-brisa")],
                                       selected: store.blowerMode, color: DS.blue) { v in Task { await store.setHvac("blower_mode", Double(v)) } }
                        }
                    }

                    // Ar / circulação
                    DSCard(title: "Circulação", icon: "arrow.triangle.2.circlepath") {
                        DSChoiceRow(options: [(0, "Recircular"), (1, "Ar externo")], selected: store.cycleMode, color: DS.teal) { v in
                            Task { await store.setHvac("cycle_mode", Double(v)) }
                        }
                    }

                    // Desembaçador
                    DSCard(title: "Desembaçador", icon: "snowflake.circle") {
                        VStack(spacing: 4) {
                            miniToggle("Dianteiro", store.frontDefrost, wide: true) { v in Task { await store.setHvac("front_defrost", on: v) } }
                            Divider().overlay(DS.border)
                            miniToggle("Traseiro", store.rearDefrost, wide: true) { v in Task { await store.setHvac("rear_defrost", on: v) } }
                        }
                    }

                    // Mais opções (submenu)
                    DSCard {
                        DisclosureGroup(isExpanded: $showMore) {
                            VStack(spacing: 4) {
                                miniToggle("Ionizador (anion)", store.anion, wide: true) { v in Task { await store.setHvac("anion", on: v) } }
                                Divider().overlay(DS.border)
                                miniToggle("Aquecimento", store.heating, wide: true) { v in Task { await store.setHvac("heating", on: v) } }
                                Divider().overlay(DS.border)
                                miniToggle("Recirc. automática (AQS)", store.aqs, wide: true) { v in Task { await store.setHvac("aqs", on: v) } }
                                Divider().overlay(DS.border)
                                miniToggle("Desembaçar automático", store.autoDefrost, wide: true) { v in Task { await store.setHvac("auto_defrost", on: v) } }
                                Divider().overlay(DS.border)
                                stepperRow(label: "Vent. banco motorista", value: "\(store.seatVentDrv)/3",
                                           dec: { adjustInt("seat_vent_drv", store.seatVentDrv, -1, 0, 3) },
                                           inc: { adjustInt("seat_vent_drv", store.seatVentDrv, 1, 0, 3) })
                                stepperRow(label: "Vent. banco passageiro", value: "\(store.seatVentPass)/3",
                                           dec: { adjustInt("seat_vent_pass", store.seatVentPass, -1, 0, 3) },
                                           inc: { adjustInt("seat_vent_pass", store.seatVentPass, 1, 0, 3) })
                            }.padding(.top, 8)
                        } label: {
                            Text("Mais opções").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                        }.tint(DS.muted)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Ar-condicionado").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
    }

    private func adjustTemp(_ control: String, _ cur: Double, _ delta: Double) {
        let v = min(32, max(16, (cur == 0 ? 22 : cur) + delta))
        Task { await store.setHvac(control, v) }
    }
    private func adjustInt(_ control: String, _ cur: Int, _ delta: Int, _ lo: Int, _ hi: Int) {
        let v = min(hi, max(lo, cur + delta))
        Task { await store.setHvac(control, Double(v)) }
    }

    private func stepperRow(label: String, value: String, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.text)
            Spacer()
            Button(action: dec) { Image(systemName: "minus.circle.fill").font(.title2).foregroundStyle(DS.muted) }
            Text(value).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text).frame(minWidth: 54)
            Button(action: inc) { Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(DS.blue) }
        }
    }

    private func miniToggle(_ title: String, _ isOn: Bool, wide: Bool = false, set: @escaping (Bool) -> Void) -> some View {
        Group {
            if wide {
                Toggle(isOn: Binding(get: { isOn }, set: set)) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.text)
                }.tint(DS.blue)
            } else {
                Button { set(!isOn) } label: {
                    Text(title).font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(isOn ? .black : DS.text)
                        .background(isOn ? DS.blue : DS.panel2)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(isOn ? .clear : DS.border, lineWidth: 1))
                }
            }
        }
    }
}
