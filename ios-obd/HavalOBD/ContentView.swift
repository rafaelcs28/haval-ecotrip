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

    var body: some View {
        NavigationStack {
            Form {
                Section("ELM327 (Bluetooth)") {
                    LabeledContent("Status") {
                        statusDot(label: bt.state.rawValue, color: btColor)
                    }
                    LabeledContent("Adaptador") {
                        Text(bt.deviceName).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if bt.rssi != 0 { LabeledContent("RSSI") { Text("\(bt.rssi) dB") } }
                    LabeledContent("ELM inicializado") {
                        Text(elm.initialized ? "✓ pronto" : "—").foregroundStyle(elm.initialized ? .green : .secondary)
                    }
                    LabeledContent("PIDs lendo") { Text("\(elm.samples.count)") }
                    Button("Buscar ELM327")  { bt.startScan() }
                    Button("Inicializar ELM327") { Task { await elm.initialize() } }
                        .disabled(bt.state != .ready)
                }

                // Log de comandos AT — diagnóstico de comunicação ELM327
                if !bt.commandLog.isEmpty {
                    Section("Log de comandos (últimos 20)") {
                        ForEach(Array(bt.commandLog.enumerated().reversed()), id: \.offset) { (i, entry) in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.dir)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(colorForDir(entry.dir))
                                    .frame(width: 28, alignment: .leading)
                                Text(entry.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                // Characteristics descobertas — debug detalhado
                if !bt.debugChars.isEmpty {
                    Section("BLE characteristics descobertas") {
                        ForEach(Array(bt.debugChars.enumerated()), id: \.offset) { (_, c) in
                            Text(c)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Lista de TODOS os dispositivos BLE detectados — clica pra conectar
                // manualmente se o filtro automático não pegou o ELM327
                if !bt.nearbyDevices.isEmpty {
                    Section("Dispositivos BLE próximos (\(bt.nearbyDevices.count))") {
                        ForEach(bt.nearbyDevices, id: \.id) { d in
                            Button {
                                bt.connectManually(id: d.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.name).font(.body)
                                        Text(d.id.uuidString.prefix(13) + "…")
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .monospaced()
                                    }
                                    Spacer()
                                    Text("\(d.rssi) dB")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .monospaced()
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                Section("Bridge MQTT (opcional)") {
                    LabeledContent("Status") {
                        statusDot(label: publisher.connected ? "online" : "offline",
                                  color: publisher.connected ? .green : .red)
                    }
                    LabeledContent("Host") {
                        TextField("mqttrafael.duckdns.org", text: $publisher.brokerHost)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledContent("Porta") {
                        TextField("8883", value: $publisher.brokerPort, format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    LabeledContent("Usuário") {
                        TextField("obd_companion", text: $publisher.brokerUser)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledContent("Senha") {
                        SecureField("•••••••", text: $publisher.brokerPass).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Topic prefix") {
                        TextField("haval/ecotrip/obd", text: $publisher.topicPrefix)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    if let err = elm.lastErrorMsg {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Button(publisher.connected ? "Desconectar" : "Conectar Bridge") {
                        if publisher.connected { publisher.disconnect() } else { publisher.connect() }
                    }
                }

                // Bridge HTTP — fonte primária do state (igual o PWA do iPhone)
                Section("Bridge HTTP (recomendado)") {
                    LabeledContent("Base URL") {
                        TextField("https://mqttrafael.duckdns.org", text: $publisher.bridgeBaseUrl)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    LabeledContent("Bearer token") {
                        SecureField("•••••••", text: $publisher.bridgeAuthToken)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    Text("Copie o token do PWA: abra o DevTools no iPhone → Application → Local Storage → bridge_token. URL é a base sem /api ou /ws.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Aplicar / Reconectar") {
                        publisher.saveConfig()
                    }
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
