//
//  ControlSheets.swift
//  Sheets full-screen abertos pela aba Drive: Controles de condução e AC.
//  Modelo do cluster iPad adaptado pra tela do iPhone (alvos de toque grandes).
//

import SwiftUI

// MARK: - Controles de condução (modo, regen, one-pedal, ESP)
struct DriveControlsSheet: View {
    @ObservedObject var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    // Seleção otimista: reflete o toque na hora; some quando o estado real chega.
    @State private var pendMode: Int?
    @State private var pendRegen: Int?
    @State private var pendOnePedal: Bool?
    @State private var pendEsp: Bool?

    private var mode: Int { pendMode ?? store.intOrNil("drive_mode") ?? -1 }
    private var regen: Int { pendRegen ?? store.intOrNil("regen_level") ?? -1 }
    private var onePedal: Bool { pendOnePedal ?? store.onePedalOn }
    private var esp: Bool { pendEsp ?? store.espOn }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DSCard(title: "Modo de condução", icon: "bolt.car") {
                        DSChoiceRow(options: [(0, "HEV"), (1, "Prior. EV"), (3, "EV Puro")],
                                    selected: mode, color: DS.green) { v in
                            pendMode = v; Task { await store.setDriveMode(v) }
                        }
                    }
                    DSCard(title: "Regeneração", icon: "arrow.triangle.2.circlepath") {
                        DSChoiceRow(options: [(0, "Normal"), (1, "Alto"), (2, "Baixo")],
                                    selected: regen, color: DS.teal) { v in
                            pendRegen = v; Task { await store.setRegen(v) }
                        }
                    }
                    DSCard(title: "One-Pedal", icon: "p.circle") {
                        DSChoiceRow(options: [(true, "Ligado"), (false, "Desligado")],
                                    selected: onePedal, color: DS.green) { v in
                            pendOnePedal = v; Task { await store.setOnePedal(v) }
                        }
                    }
                    DSCard(title: "ESP (controle de estabilidade)", icon: "car.fill") {
                        DSChoiceRow(options: [(true, "Ligado"), (false, "Desligado")],
                                    selected: esp, color: DS.green) { v in
                            pendEsp = v; Task { await store.setEsp(v) }
                        }
                    }
                    Text("Os comandos podem levar alguns segundos — o carro confirma quando aplica.")
                        .font(.caption).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Controles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        // Limpa o otimismo quando o estado real bate.
        .onChange(of: store.intOrNil("drive_mode")) { _, v in if v == pendMode { pendMode = nil } }
        .onChange(of: store.intOrNil("regen_level")) { _, v in if v == pendRegen { pendRegen = nil } }
        .onChange(of: store.onePedalOn) { _, v in if v == pendOnePedal { pendOnePedal = nil } }
        .onChange(of: store.espOn) { _, v in if v == pendEsp { pendEsp = nil } }
    }
}

// MARK: - AC (liga/desliga mestre + temperaturas)
struct ACSheet: View {
    @ObservedObject var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pendPower: Bool?
    private var acOn: Bool { pendPower ?? store.acOn }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DSCard(glass: false) {
                        VStack(spacing: 14) {
                            Image(systemName: acOn ? "snowflake" : "power")
                                .font(.system(size: 48))
                                .foregroundStyle(acOn ? DS.blue : DS.muted)
                            Text(acOn ? "Ar-condicionado ligado" : "Ar-condicionado desligado")
                                .font(.headline).foregroundStyle(DS.text)
                            DSChoiceRow(options: [(true, "Ligar"), (false, "Desligar")],
                                        selected: acOn, color: DS.blue) { v in
                                pendPower = v; Task { await store.setAcPower(v) }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    DSCard(title: "Temperatura", icon: "thermometer.medium") {
                        HStack {
                            DSMetric(value: f0(store.insideTemp), unit: "°", label: "Interna")
                            DSMetric(value: f0(store.outsideTemp), unit: "°", label: "Externa")
                        }
                    }
                    Text("Ventilação, direção do fluxo e recirculação chegam no próximo bloco.")
                        .font(.caption).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Ar-condicionado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .onChange(of: store.acOn) { _, v in if v == pendPower { pendPower = nil } }
    }
}
