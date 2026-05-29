import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Settings sheet — aberto via toque longo no canto superior direito da
//  RootView. Configura BLE/MQTT/topic. O cluster é a UI principal do app.
// ═══════════════════════════════════════════════════════════════════════════
struct SettingsView: View {
    @EnvironmentObject var bt: BluetoothManager
    @EnvironmentObject var elm: ELM327
    @EnvironmentObject var publisher: BridgePublisher
    @Environment(\.dismiss) var dismiss

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
