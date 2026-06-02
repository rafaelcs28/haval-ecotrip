//
//  NativeConfigView.swift
//  Aba Configurações — logs (popup), veículo, notificações (recolhido),
//  conta/segurança (senha, 2FA, Face ID), backup/dados (com perigo) e sobre.
//

import SwiftUI
import UniformTypeIdentifiers

struct NativeConfigView: View {
    @StateObject private var cfg = ConfigStore()
    @ObservedObject private var car = CarStore.shared

    @State private var showLogs = false
    @State private var showPair = false
    @State private var showPassword = false
    @State private var show2FA = false
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var danger: Danger?
    @AppStorage("notif_expanded") private var notifExpanded = false
    @AppStorage("faceid_lock") private var faceIDLock = false
    @AppStorage("lan_enabled") private var lanEnabled = false

    struct Danger: Identifiable { let id = UUID(); let title: String; let msg: String; let confirm: String; let action: () async -> Void }

    private let laitems: [(String, String)] = [("la_charge","Recarga"),("la_preclimat","Pré-climatização"),("la_trip","Viagem"),("la_motor","Motor ligado"),("la_security","Segurança")]
    private let pushitems: [(String, String)] = [("charge_start","Início de recarga"),("charge_end","Fim de recarga"),("charge_stopped","Parou de recarregar"),("trip_end","Fim de viagem"),("door_open","Porta aberta"),("engine_on","Motor ligado"),("geofence_arrival","Chegada a local"),("tyre_low","Pneu baixo"),("refuel_detected","Abastecimento"),("batt12_low","Bateria 12V baixa"),("daily_summary","Resumo diário")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    logsCard
                    veiculoCard
                    notificacoesCard
                    contaCard
                    backupCard
                    avancadoCard
                    sobreCard
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Configurações").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar).toolbarBackground(DS.bg, for: .navigationBar)
        }
        .task { await cfg.loadAll() }
        .sheet(isPresented: $showLogs) { LogsSheet() }
        .sheet(isPresented: $showPassword) { PasswordSheet(cfg: cfg) }
        .sheet(isPresented: $show2FA) { TwoFASheet(cfg: cfg) }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url) {
                Task { _ = await cfg.restoreBackup(data) }
            }
        }
        .confirmationDialog(danger?.title ?? "", isPresented: .init(get: { danger != nil }, set: { if !$0 { danger = nil } }), presenting: danger) { d in
            Button(d.confirm, role: .destructive) { Task { await d.action(); danger = nil } }
            Button("Cancelar", role: .cancel) { danger = nil }
        } message: { d in Text(d.msg) }
    }

    // MARK: Logs
    private var logsCard: some View {
        DSCard { rowButton(icon: "list.bullet.rectangle", title: "Logs de eventos", subtitle: "Histórico e filtros") { showLogs = true } }
    }

    // MARK: Veículo
    private var veiculoCard: some View {
        let limit = Int(car.num("charge_limit_pct"))
        return DSCard(title: "Veículo", icon: "car.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("LIMITE DE CARGA (SOC)").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
                HStack(spacing: 6) {
                    ForEach([50,60,70,80,90,100], id: \.self) { p in
                        let on = limit == p
                        Button { Task { await cfg.setChargeLimit(p) } } label: {
                            Text("\(p)").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).frame(height: 38)
                                .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                Divider().overlay(DS.border)
                Toggle(isOn: $lanEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("LAN direta", systemImage: "wifi").font(.system(size: 14)).foregroundStyle(DS.text)
                        Text("Conecta direto ao carro na mesma Wi-Fi. Reabra o app ao alterar.").font(.caption2).foregroundStyle(DS.muted)
                    }
                }.tint(DS.green)
                Divider().overlay(DS.border)
                rowButton(icon: "qrcode", title: "Parear carro", subtitle: "Gera um código pro app do carro") {
                    cfg.pairCode = nil; showPair = true; Task { await cfg.generatePair() }
                }
            }
        }
        .alert("Código de pareamento", isPresented: $showPair) {
            Button("OK") {}
        } message: { Text(cfg.pairCode ?? "Gerando…") }
    }

    // MARK: Notificações (recolhido, persiste)
    private var notificacoesCard: some View {
        DSCard {
            DisclosureGroup(isExpanded: $notifExpanded) {
                VStack(spacing: 4) {
                    Text("LIVE ACTIVITIES").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    ForEach(laitems, id: \.0) { k, label in
                        Toggle(label, isOn: Binding(get: { cfg.laPrefs[k] ?? true }, set: { v in Task { await cfg.setLa(k, v) } })).tint(DS.green).font(.system(size: 14))
                    }
                    Text("NOTIFICAÇÕES PUSH").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    ForEach(pushitems, id: \.0) { k, label in
                        Toggle(label, isOn: Binding(get: { cfg.pushPrefs[k] ?? true }, set: { v in Task { await cfg.setPush(k, v) } })).tint(DS.green).font(.system(size: 14))
                    }
                }
            } label: {
                Label("Notificações", systemImage: "bell.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
            }.tint(DS.muted)
        }
    }
    // MARK: Conta e segurança
    private var contaCard: some View {
        DSCard(title: "Conta e segurança", icon: "lock.shield.fill") {
            VStack(spacing: 4) {
                Toggle(isOn: $faceIDLock) { Label("Desbloquear com Face ID", systemImage: "faceid").font(.system(size: 14)).foregroundStyle(DS.text) }.tint(DS.green)
                Divider().overlay(DS.border)
                rowButton(icon: "key.fill", title: "Alterar senha", subtitle: nil) { showPassword = true }
                Divider().overlay(DS.border)
                rowButton(icon: "checkmark.shield.fill", title: "Verificação em 2 etapas", subtitle: cfg.twofaEnabled ? "Ativada" : "Desativada") { show2FA = true }
            }
        }
    }

    // MARK: Backup e dados
    private var backupCard: some View {
        DSCard(title: "Backup e dados", icon: "externaldrive.fill") {
            VStack(spacing: 4) {
                rowButton(icon: "square.and.arrow.up", title: "Exportar backup", subtitle: nil) { Task { shareURL = await cfg.exportBackup() } }
                Divider().overlay(DS.border)
                rowButton(icon: "square.and.arrow.down", title: "Importar backup", subtitle: nil) { importing = true }
                Divider().overlay(DS.border)
                rowButton(icon: "trash", title: "Limpar cache local", subtitle: "Só neste aparelho") {
                    URLCache.shared.removeAllCachedResponses(); cfg.toast = "Cache limpo"
                }
                Divider().overlay(DS.border)
                dangerRow("Apagar histórico de condução", "Remove os modos de condução registrados.") {
                    Task { await cfg.adminAction("/api/drive-history/clear") }
                }
                dangerRow("Apagar dados do servidor", "Apaga recargas e viagens do servidor. Ação IRREVERSÍVEL.") {
                    Task { await cfg.adminAction("/api/admin/clear-history") }
                }
            }
        }
    }

    // MARK: Avançado
    private var avancadoCard: some View {
        DSCard {
            DisclosureGroup {
                VStack(spacing: 4) {
                    rowButton(icon: "arrow.triangle.2.circlepath", title: "Recalcular custo das viagens", subtitle: nil) { Task { await cfg.adminAction("/api/admin/recompute-trip-costs") } }
                    Divider().overlay(DS.border)
                    rowButton(icon: "mappin.and.ellipse", title: "Reprocessar nomes de locais", subtitle: nil) { Task { await cfg.adminAction("/api/admin/reprocess-places") } }
                    Divider().overlay(DS.border)
                    dangerRow("Reiniciar bridge", "O servidor reinicia (alguns segundos offline).") { Task { await cfg.adminAction("/api/admin/restart") } }
                    dangerRow("Atualizar do GitHub", "Puxa a última versão e reinicia o servidor.") { Task { await cfg.adminAction("/api/admin/update") } }
                }
            } label: { Label("Avançado", systemImage: "gearshape.2.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text) }.tint(DS.muted)
        }
    }

    // MARK: Sobre
    private var sobreCard: some View {
        DSCard(title: "Sobre", icon: "info.circle.fill") {
            VStack(spacing: 8) {
                aboutRow("App", appVersion)
                aboutRow("Bridge", cfg.gitCommit)
                aboutRow("Node", cfg.nodeVersion)
                aboutRow("Uptime", cfg.bridgeUptime)
                aboutRow("Broker", cfg.mqttHost)
            }
        }
    }
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: helpers
    private func rowButton(icon: String, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(DS.muted).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.text)
                    if let s = subtitle { Text(s).font(.caption).foregroundStyle(DS.muted) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }.buttonStyle(.plain)
    }
    private func dangerRow(_ title: String, _ msg: String, _ action: @escaping () async -> Void) -> some View {
        Button { danger = .init(title: title + "?", msg: msg, confirm: title, action: action) } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(DS.red).frame(width: 22)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.red)
                Spacer()
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }.buttonStyle(.plain)
    }
    private func aboutRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.system(size: 14)).foregroundStyle(DS.muted); Spacer(); Text(v).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.text) }
    }
}

// MARK: - Sheets auxiliares
struct PasswordSheet: View {
    @ObservedObject var cfg: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var pwd = ""; @State private var pwd2 = ""; @State private var msg = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Nova senha") {
                    SecureField("Senha", text: $pwd)
                    SecureField("Confirmar", text: $pwd2)
                }
                if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(DS.red) }
                Button("Salvar") {
                    guard pwd.count >= 4, pwd == pwd2 else { msg = "Senhas não conferem (mín. 4)"; return }
                    Task { if await cfg.changePassword(pwd) { dismiss() } else { msg = "Falha ao salvar" } }
                }
            }
            .navigationTitle("Alterar senha").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

struct TwoFASheet: View {
    @ObservedObject var cfg: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var qr: UIImage?; @State private var code = ""; @State private var msg = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if cfg.twofaEnabled {
                        Text("2FA ativada.").foregroundStyle(DS.text)
                        TextField("Código atual p/ desativar", text: $code).keyboardType(.numberPad)
                            .padding(10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10))
                        Button("Desativar 2FA", role: .destructive) {
                            Task { if await cfg.twofaDisable(code) { dismiss() } else { msg = "Código inválido" } }
                        }
                    } else {
                        if let qr { Image(uiImage: qr).resizable().frame(width: 200, height: 200) }
                        Text("Escaneie no app autenticador e digite o código.").font(.caption).foregroundStyle(DS.muted)
                        TextField("Código de 6 dígitos", text: $code).keyboardType(.numberPad)
                            .padding(10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10))
                        Button("Ativar 2FA") {
                            Task { if await cfg.twofaActivate(code) { dismiss() } else { msg = "Código inválido" } }
                        }
                    }
                    if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(DS.red) }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Verificação 2FA").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .task {
            if !cfg.twofaEnabled, let s = await cfg.twofaSetup() {
                if let comma = s.qr.range(of: ","), let data = Data(base64Encoded: String(s.qr[comma.upperBound...])) { qr = UIImage(data: data) }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable { public var id: String { absoluteString } }
