//
//  ConfigV2View.swift
//  Config v2 — grupos iOS com estado inline (design-v2/README.md, frames 7a/7b).
//  V1 (NativeConfigView) permanece intacta; troca via flag ui_v2.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConfigV2View: View {
    @StateObject private var cfg = ConfigStore()
    @ObservedObject private var car = CarStore.shared

    @AppStorage("faceid_lock") private var faceIDLock = false
    @AppStorage("lan_enabled") private var lanEnabled = false
    @AppStorage("glass_enabled") private var glassEnabled = true
    @AppStorage("reduce_anim") private var reduceAnim = false

    @State private var showLogs = false
    @State private var showPair = false
    @State private var showPassword = false
    @State private var show2FA = false
    @State private var showNotif = false
    @State private var showVehicle = false
    @State private var showPlaces = false
    @State private var showAutomations = false
    @State private var showNotifCenter = false
    @State private var showSpeedFence = false
    @State private var showParkGuard = false
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var latencyMs: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    group("VEÍCULO") {
                        vehicleRow
                        div
                        row(icon: "mappin.and.ellipse", tint: DS.teal, title: "Locais conhecidos",
                            sub: "Casa, trabalho, postos…") { showPlaces = true }
                        div
                        row(icon: "wand.and.stars", tint: DS.orange, title: "Automações",
                            sub: "Ações no carro por local ou horário") { showAutomations = true }
                        div
                        row(icon: "shield.lefthalf.filled", tint: DS.blue, title: "Guarda-estacionamento",
                            sub: "alerta se o carro se mover sem você") { showParkGuard = true }
                        div
                        row(icon: "qrcode", tint: DS.text2, title: "Parear carro",
                            sub: "Gera um código pro app do carro") { showPair = true }
                    }
                    group("ALERTAS E NOTIFICAÇÕES") {
                        row(icon: "bell.fill", tint: DS.green, title: "Notificações",
                            value: "Live Activities + push") { showNotif = true }
                        div
                        row(icon: "exclamationmark.triangle.fill", tint: DS.yellow, title: "Central de alertas",
                            sub: "Histórico de alertas recebidos") { showNotifCenter = true }
                        div
                        row(icon: "gauge.open.with.lines.needle.33percent", tint: DS.orange, title: "Cerca de velocidade",
                            sub: "alerta se passar do limite (outro motorista)") { showSpeedFence = true }
                    }
                    group("APARÊNCIA") {
                        toggleRow(icon: "square.on.square.intersection.dashed", tint: DS.teal,
                                  title: "Liquid Glass", sub: "iOS 26+ · só na camada flutuante",
                                  isOn: $glassEnabled)
                        div
                        toggleRow(icon: "arrow.triangle.2.circlepath", tint: DS.green,
                                  title: "Reduzir animações", sub: "desliga pulsos e loops",
                                  isOn: $reduceAnim)
                        div
                        rowLabel(icon: "moon.fill", tint: DS.text2, title: "Tema",
                                 value: "Escuro · fixo", chevron: false)
                    }
                    group("CONTA E SEGURANÇA") {
                        toggleRow(icon: "faceid", tint: DS.blue, title: "Exigir Face ID",
                                  sub: nil, isOn: $faceIDLock)
                        div
                        row(icon: "key.fill", tint: DS.text2, title: "Alterar senha") { showPassword = true }
                        div
                        row(icon: "checkmark.shield.fill", tint: DS.green, title: "Verificação em 2 etapas",
                            value: cfg.twofaEnabled ? "Ativada" : "Desativada") { show2FA = true }
                        div
                        row(icon: "server.rack", tint: DS.teal, title: "Instância", value: instanceLabel) {
                            NotificationCenter.default.post(name: .openHavalSettings, object: nil)
                        }
                    }
                    group("DADOS") {
                        row(icon: "square.and.arrow.up", tint: DS.green, title: "Exportar backup") {
                            Task { shareURL = await cfg.exportBackup() }
                        }
                        div
                        row(icon: "square.and.arrow.down", tint: DS.teal, title: "Importar backup") { importing = true }
                        div
                        row(icon: "list.bullet.rectangle", tint: DS.text2, title: "Logs de eventos",
                            sub: "Histórico e filtros") { showLogs = true }
                        div
                        row(icon: "trash", tint: DS.text2, title: "Limpar cache local",
                            sub: "Apaga os dados baixados; recarrega ao reabrir") {
                            OfflineCache.clearAll(); cfg.toast = "Cache limpo — reabra as abas"
                        }
                        div
                        NavigationLink {
                            DiagnosticoV2View(cfg: cfg, latencyMs: latencyMs)
                        } label: {
                            rowLabel(icon: "waveform.path.ecg", tint: DS.green, title: "Diagnóstico",
                                     value: latencyMs.map { "WS 1 Hz · \($0) ms" } ?? "WS 1 Hz", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                    group("AVANÇADO") {
                        toggleRow(icon: "wifi", tint: DS.teal, title: "LAN direta",
                                  sub: "Direto ao carro na mesma Wi-Fi · reabra o app", isOn: $lanEnabled)
                        div
                        confirm(icon: "arrow.triangle.2.circlepath", tint: DS.text2,
                                title: "Recalcular custo das viagens",
                                msg: "Recalcula o custo de todas as viagens com os preços atuais.") {
                            let ok = await cfg.adminAction("/api/admin/recompute-trip-costs")
                            cfg.toast = ok ? "✓ Recalculado" : "✗ Falhou"
                        }
                        div
                        confirm(icon: "mappin.and.ellipse", tint: DS.text2,
                                title: "Reprocessar nomes de locais",
                                msg: "Re-identifica TODAS as viagens/recargas. Roda em segundo plano (~1/seg); depois limpe o cache local.") {
                            let ok = await cfg.reprocessPlaces()
                            cfg.toast = ok ? "✓ Reprocessando em 2º plano…" : "✗ Falhou"
                        }
                        div
                        confirm(icon: "arrow.clockwise", tint: DS.orange, title: "Reiniciar bridge",
                                destructive: true,
                                msg: "O servidor reinicia (alguns segundos offline).") {
                            let ok = await cfg.adminAction("/api/admin/restart")
                            cfg.toast = ok ? "✓ Reiniciando…" : "✗ Falhou"
                        }
                        div
                        confirm(icon: "arrow.down.circle", tint: DS.orange, title: "Atualizar do GitHub",
                                destructive: true,
                                msg: "Puxa a última versão e reinicia o servidor.") {
                            let ok = await cfg.adminAction("/api/admin/update")
                            cfg.toast = ok ? "✓ Atualizando…" : "✗ Falhou"
                        }
                        div
                        confirm(icon: "exclamationmark.triangle.fill", tint: DS.red,
                                title: "Apagar dados do servidor", destructive: true,
                                msg: "Apaga recargas e viagens do servidor. Ação IRREVERSÍVEL.") {
                            let ok = await cfg.adminAction("/api/admin/clear-history")
                            cfg.toast = ok ? "✓ Dados apagados" : "✗ Falhou"
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            }
            .background(DS.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { car.start(); await cfg.loadAll(); await measureLatency() }
        .sheet(isPresented: $showLogs) { LogsSheet() }
        .sheet(isPresented: $showPassword) { PasswordSheet(cfg: cfg) }
        .sheet(isPresented: $show2FA) { TwoFASheet(cfg: cfg) }
        .sheet(isPresented: $showPair) { PairCodeSheet(cfg: cfg) }
        .sheet(isPresented: $showVehicle) { VehicleSheet(cfg: cfg) }
        .sheet(isPresented: $showPlaces) { KnownPlacesSheet(cfg: cfg) }
        .sheet(isPresented: $showAutomations) { AutomationsSheet(cfg: cfg) }
        .sheet(isPresented: $showNotif) { NotificationsSheet(cfg: cfg) }
        .sheet(isPresented: $showNotifCenter) { NotificationsCenterSheet() }
        .sheet(isPresented: $showSpeedFence) { SpeedFenceSheet() }
        .sheet(isPresented: $showParkGuard) { ParkGuardSheet() }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data else { cfg.toast = "Falha ao ler arquivo"; return }
            Task { let ok = await cfg.restoreBackup(data); cfg.toast = ok ? "✓ Backup importado" : "✗ Falha ao importar" }
        }
        .overlay(alignment: .bottom) {
            if let t = cfg.toast {
                Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    .padding(.horizontal, 18).padding(.vertical, 12).background(DS.panel2)
                    .clipShape(Capsule()).overlay(Capsule().stroke(DS.border, lineWidth: 1))
                    .padding(.bottom, 30).transition(.opacity)
                    .task { try? await Task.sleep(nanoseconds: 2_200_000_000); cfg.toast = nil }
            }
        }
        .animation(.easeInOut, value: cfg.toast)
    }

    // MARK: header — título + chip de saúde do bridge

    private var header: some View {
        HStack(alignment: .center) {
            Text("Config")
                .font(.system(size: 24, weight: .heavy)).tracking(-0.5)
                .foregroundStyle(DS.text)
            Spacer()
            bridgeChip
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var bridgeChip: some View {
        if car.connected {
            HStack(spacing: 6) {
                BreatheDot(color: DS.green)
                Text(latencyMs.map { "BRIDGE OK · \($0) MS" } ?? "BRIDGE OK")
                    .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                    .foregroundStyle(DS.green)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(DS.green.opacity(0.12)).clipShape(Capsule())
            .overlay(Capsule().stroke(DS.green.opacity(0.3), lineWidth: 1))
        } else {
            HStack(spacing: 6) {
                PulseDot(color: DS.red)
                Text("BRIDGE FORA")
                    .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                    .foregroundStyle(DS.red)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(DS.red.opacity(0.12)).clipShape(Capsule())
            .overlay(Capsule().stroke(DS.red.opacity(0.35), lineWidth: 1))
        }
    }

    private func measureLatency() async {
        guard let url = URL(string: "\(BridgeRouter.shared.currentURL)/api/whoami") else { return }
        var r = URLRequest(url: url); r.timeoutInterval = 8
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        let t0 = Date()
        if (try? await URLSession.shared.data(for: r)) != nil {
            latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        }
    }

    // MARK: linhas de dado

    private var vehicleRow: some View {
        Button { showVehicle = true } label: {
            HStack(spacing: 12) {
                Image("car_h6")
                    .resizable().scaledToFit()
                    .frame(width: 34, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.modelName.isEmpty ? "Haval H6 PHEV" : cfg.modelName)
                        .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.text)
                    Text(car.carOnline ? "head-unit conectado via MQTT" : "head-unit offline")
                        .font(.system(size: 11)).foregroundStyle(DS.muted)
                }
                Spacer()
                if car.num("charge_limit_pct") > 0 {
                    Text("carga \(chargeLimitText)")
                        .font(.system(size: 12)).foregroundStyle(DS.text2)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chargeLimitText: String {
        let l = car.num("charge_limit_pct")
        return l > 0 ? "\(Fmt.int(l))%" : "—"
    }

    private var instanceLabel: String {
        let host = URL(string: Settings.bridgeURL)?.host ?? "—"
        return host == "localhost" || host.hasPrefix("192.168") || host.hasPrefix("127.") ? "bridge local" : host
    }

    // MARK: grupo + row builders

    private var div: some View { Divider().overlay(DS.divider).padding(.leading, 51) }

    private func group<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
                .foregroundStyle(DS.muted)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(DS.panel)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.border, lineWidth: 1))
        }
    }

    private func iconBox(_ icon: String, _ tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func rowLabel(icon: String, tint: Color, title: String, sub: String? = nil,
                          value: String? = nil, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            iconBox(icon, tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.text)
                if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(DS.muted) }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.system(size: 12.5)).foregroundStyle(DS.text2)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func row(icon: String, tint: Color, title: String, sub: String? = nil,
                     value: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(icon: icon, tint: tint, title: title, sub: sub, value: value, chevron: true)
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(icon: String, tint: Color, title: String, sub: String?,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconBox(icon, tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.text)
                if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(DS.muted) }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().tint(DS.green)
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
    }

    private func confirm(icon: String, tint: Color, title: String, destructive: Bool = false,
                         msg: String, onConfirm: @escaping () async -> Void) -> some View {
        ConfirmRowV2(icon: icon, tint: tint, title: title, destructive: destructive,
                     msg: msg, onConfirm: onConfirm)
    }
}

// Linha de confirmação estilo v2 (popover ancorado, mesma UX do ConfirmRow v1).
private struct ConfirmRowV2: View {
    let icon: String
    let tint: Color
    let title: String
    var destructive: Bool = false
    let msg: String
    let onConfirm: () async -> Void
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(destructive ? DS.red : tint)
                    .frame(width: 26, height: 26)
                    .background((destructive ? DS.red : tint).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(destructive ? DS.red : DS.text)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(spacing: 14) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text).multilineTextAlignment(.center)
                Text(msg).font(.caption).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Cancelar") { show = false }
                        .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(DS.text)
                        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 11))
                    Button(destructive ? "Apagar" : "Confirmar") { show = false; Task { await onConfirm() } }
                        .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(.black)
                        .background(destructive ? DS.red : DS.green)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .padding(18).frame(width: 300).background(DS.panel)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Diagnóstico — sobre + conexão

struct DiagnosticoV2View: View {
    @ObservedObject var cfg: ConfigStore
    @ObservedObject private var car = CarStore.shared
    var latencyMs: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                diagRow("Latência do bridge", latencyMs.map { "\($0) ms" } ?? "—")
                diagRow("App", appVersion)
                diagRow("Carro (APK)", cfg.carVersion)
                diagRow("Bridge", cfg.gitCommit)
                diagRow("Node", cfg.nodeVersion)
                diagRow("Uptime", cfg.bridgeUptime)
                diagRow("Broker", cfg.mqttHost)
                diagRow("IP do carro", car.carIP.isEmpty ? "—" : car.carIP, last: true)
            }
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.border, lineWidth: 1))
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .navigationTitle("Diagnóstico").navigationBarTitleDisplayMode(.inline)
        .legacyDarkNavBar()
    }

    private func diagRow(_ k: String, _ v: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(k).font(.system(size: 13.5)).foregroundStyle(DS.muted)
                Spacer()
                Text(v).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if !last { Divider().overlay(DS.divider).padding(.leading, 14) }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
