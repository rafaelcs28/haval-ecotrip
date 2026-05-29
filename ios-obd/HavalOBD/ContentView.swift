import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Settings sheet — aberto via toque longo no canto superior direito da
//  RootView. Configura BLE/MQTT/topic. O cluster é a UI principal do app.
// ═══════════════════════════════════════════════════════════════════════════
struct SettingsView: View {
    @EnvironmentObject var bt: BluetoothManager
    @EnvironmentObject var elm: ELM327
    @EnvironmentObject var publisher: BridgePublisher
    @EnvironmentObject var discovery: OBDDiscovery
    @EnvironmentObject var channel: OBDBridgeChannel
    @Environment(\.dismiss) var dismiss
    @State private var copiedFeedback = false
    @State private var bridgePassword: String = ""
    @State private var bridgeTotp: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // Bridge HTTP — fonte primária do state (igual o PWA do iPhone)
                Section("Bridge HTTP (recomendado)") {
                    LabeledContent("Base URL") {
                        TextField("https://mqttrafael.duckdns.org", text: $publisher.bridgeBaseUrl)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    LabeledContent("Senha do app") {
                        SecureField("digite a senha do PWA", text: $bridgePassword)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    if publisher.needs2FA {
                        LabeledContent("Código 2FA") {
                            TextField("6 dígitos", text: $bridgeTotp)
                                .multilineTextAlignment(.trailing).autocorrectionDisabled()
                                .keyboardType(.numberPad)
                        }
                    }
                    if let err = publisher.loginError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        if !publisher.bridgeAuthToken.isEmpty && !publisher.needs2FA {
                            Label("Logado", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button(publisher.loggingIn ? "Entrando…" : "Entrar") {
                            Task {
                                await publisher.login(password: bridgePassword, totp: bridgeTotp)
                                if !publisher.bridgeAuthToken.isEmpty && !publisher.needs2FA {
                                    bridgePassword = ""
                                    bridgeTotp = ""
                                }
                            }
                        }
                        .disabled(bridgePassword.isEmpty || publisher.bridgeBaseUrl.isEmpty || publisher.loggingIn)
                    }
                    Text("Use a mesma senha do PWA do iPhone. Se tiver 2FA ativo, vai aparecer campo pro código.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Modo Discovery — varre PIDs Mode 22 customizados do Haval
                Section("Discovery Mode 22 (PIDs custom Haval)") {
                    if discovery.isRunning {
                        LabeledContent("Status") {
                            Text(discovery.statusMsg)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        ProgressView(value: discovery.progress).tint(.green)
                        LabeledContent("PIDs achados") {
                            Text("\(discovery.foundPids.count)")
                                .foregroundStyle(.green).bold()
                        }
                        Button("Parar varredura", role: .destructive) { discovery.stop() }
                    } else {
                        if !discovery.foundPids.isEmpty {
                            LabeledContent("Última varredura") {
                                Text("\(discovery.foundPids.count) achados de \(discovery.totalScanned) testados")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(discovery.statusMsg.isEmpty
                             ? "Brute force dos PIDs custom do Haval (Mode 22). Cobre BMS, motor elétrico, TPMS, HVAC. Demora ~7min. **Precisa estar em DRIVING READY.**"
                             : discovery.statusMsg)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Iniciar varredura") { discovery.start() }
                            .disabled(!elm.initialized)
                        if !discovery.foundPids.isEmpty {
                            Button {
                                let json = discovery.exportJSON()
                                UIPasteboard.general.string = json
                                copiedFeedback = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedFeedback = false
                                }
                            } label: {
                                HStack {
                                    Image(systemName: copiedFeedback ? "checkmark.circle.fill" : "doc.on.clipboard")
                                    Text(copiedFeedback ? "Copiado!" : "Copiar JSON pra clipboard")
                                }
                            }
                        }
                    }
                    // Lista compacta dos PIDs achados
                    if !discovery.foundPids.isEmpty {
                        ForEach(Array(discovery.foundPids.enumerated()), id: \.offset) { (_, entry) in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.ecu).font(.caption2).foregroundStyle(.blue).bold()
                                    Text(String(format: "22 %04X", entry.pid))
                                        .font(.caption.monospaced()).bold()
                                }
                                Text(entry.response.prefix(60))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section("Debug") {
                    Toggle("Mostrar overlay de PIDs no cluster", isOn: $channel.debugMode)
                    Text("Quando ligado, aparece uma tabela flutuante no cluster com TODOS os PIDs lidos (id, valor, unidade, idade). Útil pra diagnosticar quais PIDs estão respondendo.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Sobre") {
                    LabeledContent("App") { Text("Haval OBD v1.0") }
                    LabeledContent("Cluster") { Text("local · offline-first").foregroundStyle(.secondary) }
                    Text("O cluster roda 100% offline com dados vindo direto do ELM327 via Bluetooth. O Bridge MQTT é opcional, pra sincronizar com outros dispositivos.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Fechar") {
                        publisher.saveConfig()
                        dismiss()
                    }.frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("✕") { dismiss() }
                }
            }
        }
    }

    private func colorForDir(_ dir: String) -> Color {
        switch dir {
        case "→":   return .blue
        case "←":   return .green
        case "ERR": return .red
        case "BT":  return .yellow
        default:    return .secondary
        }
    }

    private var btColor: Color {
        switch bt.state {
        case .ready:                 return .green
        case .connecting, .scanning: return .yellow
        default:                     return .red
        }
    }
    private func statusDot(label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
