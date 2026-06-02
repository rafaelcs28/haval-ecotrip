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
    @State private var showNotif = false
    @State private var showVehicle = false
    @State private var showPlaces = false
    @State private var shareURL: URL?
    @State private var importing = false
    @AppStorage("faceid_lock") private var faceIDLock = false
    @AppStorage("lan_enabled") private var lanEnabled = false

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

    // MARK: Logs
    private var logsCard: some View {
        DSCard { rowButton(icon: "list.bullet.rectangle", title: "Logs de eventos", subtitle: "Histórico e filtros") { showLogs = true } }
    }

    // MARK: Veículo (submenu) + Locais + LAN + pareamento
    private var veiculoCard: some View {
        DSCard(title: "Veículo", icon: "car.fill") {
            VStack(spacing: 4) {
                rowButton(icon: "slider.horizontal.3", title: "Veículo", subtitle: "Limite de carga, modelo e chassi") { showVehicle = true }
                Divider().overlay(DS.border)
                rowButton(icon: "mappin.and.ellipse", title: "Locais conhecidos", subtitle: "Casa, trabalho, postos…") { showPlaces = true }
                Divider().overlay(DS.border)
                Toggle(isOn: $lanEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("LAN direta", systemImage: "wifi").font(.system(size: 14)).foregroundStyle(DS.text)
                        Text("Conecta direto ao carro na mesma Wi-Fi. Reabra o app ao alterar.").font(.caption2).foregroundStyle(DS.muted)
                    }
                }.tint(DS.green)
                Divider().overlay(DS.border)
                rowButton(icon: "qrcode", title: "Parear carro", subtitle: "Gera um código pro app do carro") { showPair = true }
            }
        }
        .sheet(isPresented: $showPair) { PairCodeSheet(cfg: cfg) }
        .sheet(isPresented: $showVehicle) { VehicleSheet(cfg: cfg) }
        .sheet(isPresented: $showPlaces) { KnownPlacesSheet(cfg: cfg) }
    }

    // MARK: Notificações (catálogo completo em sheet)
    private var notificacoesCard: some View {
        DSCard {
            rowButton(icon: "bell.fill", title: "Notificações", subtitle: "Live Activities + alertas push") { showNotif = true }
        }
        .sheet(isPresented: $showNotif) { NotificationsSheet(cfg: cfg) }
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
                ConfirmRow(icon: "exclamationmark.triangle.fill", title: "Apagar dados do servidor", destructive: true,
                           msg: "Apaga recargas e viagens do servidor. Ação IRREVERSÍVEL.") {
                    let ok = await cfg.adminAction("/api/admin/clear-history"); cfg.toast = ok ? "✓ Dados apagados" : "✗ Falhou"
                }
            }
        }
    }

    // MARK: Avançado
    private var avancadoCard: some View {
        DSCard {
            DisclosureGroup {
                VStack(spacing: 4) {
                    ConfirmRow(icon: "arrow.triangle.2.circlepath", title: "Recalcular custo das viagens",
                               msg: "Recalcula o custo de todas as viagens com os preços atuais.") {
                        let ok = await cfg.adminAction("/api/admin/recompute-trip-costs"); cfg.toast = ok ? "✓ Recalculado" : "✗ Falhou"
                    }
                    Divider().overlay(DS.border)
                    ConfirmRow(icon: "mappin.and.ellipse", title: "Reprocessar nomes de locais",
                               msg: "Reidentifica os locais conhecidos das viagens/recargas.") {
                        let ok = await cfg.adminAction("/api/admin/reprocess-places"); cfg.toast = ok ? "✓ Reprocessado" : "✗ Falhou"
                    }
                    Divider().overlay(DS.border)
                    ConfirmRow(icon: "arrow.clockwise", title: "Reiniciar bridge", destructive: true,
                               msg: "O servidor reinicia (alguns segundos offline).") {
                        let ok = await cfg.adminAction("/api/admin/restart"); cfg.toast = ok ? "✓ Reiniciando…" : "✗ Falhou"
                    }
                    ConfirmRow(icon: "arrow.down.circle", title: "Atualizar do GitHub", destructive: true,
                               msg: "Puxa a última versão e reinicia o servidor.") {
                        let ok = await cfg.adminAction("/api/admin/update"); cfg.toast = ok ? "✓ Atualizando…" : "✗ Falhou"
                    }
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
    private func aboutRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.system(size: 14)).foregroundStyle(DS.muted); Spacer(); Text(v).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.text) }
    }
}

// Linha com confirmação em popover ancorado (nasce do ponto tocado).
struct ConfirmRow: View {
    let icon: String
    let title: String
    var destructive: Bool = false
    let msg: String
    let onConfirm: () async -> Void
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(destructive ? DS.red : DS.muted).frame(width: 22)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(destructive ? DS.red : DS.text)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(spacing: 14) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text).multilineTextAlignment(.center)
                Text(msg).font(.caption).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Cancelar") { show = false }
                        .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(DS.text).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 11))
                    Button(destructive ? "Apagar" : "Confirmar") { show = false; Task { await onConfirm() } }
                        .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(.black).background(destructive ? DS.red : DS.green).clipShape(RoundedRectangle(cornerRadius: 11)).font(.system(size: 15, weight: .bold))
                }
            }
            .padding(18).frame(width: 300).background(DS.panel)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// Código de pareamento (gera ao abrir; atualiza reativamente).
struct PairCodeSheet: View {
    @ObservedObject var cfg: ConfigStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "qrcode").font(.system(size: 44)).foregroundStyle(DS.green)
                Text("No app do carro: Ajustes → Parear → digite o código").font(.subheadline).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                if let code = cfg.pairCode {
                    Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).foregroundStyle(DS.text).tracking(4)
                    Text("Válido por 10 minutos").font(.caption).foregroundStyle(DS.muted)
                } else {
                    ProgressView().tint(DS.green).padding(.top, 8)
                }
                Spacer()
            }.padding(24)
            .frame(maxWidth: .infinity)
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Parear carro").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
        }
        .task { cfg.pairCode = nil; await cfg.generatePair() }
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
