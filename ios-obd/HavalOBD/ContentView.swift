import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bt: BluetoothManager
    @EnvironmentObject var elm: ELM327
    @EnvironmentObject var publisher: BridgePublisher
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    actionsCard
                    if !elm.samples.isEmpty { samplesCard }
                    if let err = elm.lastErrorMsg {
                        Text("⚠️ \(err)")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("Haval OBD Companion")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(publisher) }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ELM327", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                statusDot(label: bt.state.rawValue, color: btColor)
            }
            HStack {
                Text(bt.deviceName).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if bt.rssi != 0 { Text("RSSI \(bt.rssi)dB").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Label("Bridge MQTT", systemImage: "network")
                    .font(.headline)
                Spacer()
                statusDot(label: publisher.connected ? "online" : "offline",
                          color: publisher.connected ? .green : .red)
            }
            HStack {
                Text(publisher.brokerHost).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if let t = publisher.lastSentAt {
                    Text("último envio: \(t, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 18) {
                statBox(value: "\(elm.samples.count)", label: "PIDs ativos")
                statBox(value: "\(publisher.sampleCount)", label: "Snapshots enviados")
                statBox(value: elm.initialized ? "✓" : "—", label: "ELM init")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var actionsCard: some View {
        HStack(spacing: 12) {
            actionButton(title: "Buscar ELM327", icon: "magnifyingglass") {
                bt.startScan()
            }
            actionButton(title: elm.initialized ? "Reset ELM" : "Inicializar", icon: "arrow.clockwise") {
                Task { await elm.initialize() }
            }
            actionButton(title: publisher.connected ? "Desconectar" : "Conectar Bridge", icon: "icloud") {
                if publisher.connected { publisher.disconnect() } else { publisher.connect() }
            }
        }
    }

    private var samplesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leituras ao vivo").font(.headline).padding(.bottom, 4)
            ForEach(elm.samples.values.sorted(by: { $0.pidId < $1.pidId }), id: \.pidId) { s in
                HStack {
                    Text(s.pidId).font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    Text(s.value.map { String(format: "%.2f", $0) } ?? "—")
                        .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                    Text(s.unit).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // ── helpers ───────────────────────────────────────────────────────────
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
    private func statBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).fontWeight(.medium)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Settings
// ═══════════════════════════════════════════════════════════════════════════
struct SettingsView: View {
    @EnvironmentObject var publisher: BridgePublisher
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("MQTT Bridge") {
                    LabeledContent("Host") {
                        TextField("mqttrafael.duckdns.org", text: $publisher.brokerHost)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledContent("Porta") {
                        TextField("8883", value: $publisher.brokerPort, format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    LabeledContent("Usuário") {
                        TextField("obd_companion", text: $publisher.brokerUser)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledContent("Senha") {
                        SecureField("•••••••", text: $publisher.brokerPass)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Topic prefix") {
                        TextField("haval/ecotrip/obd", text: $publisher.topicPrefix)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                Section {
                    Button("Salvar e voltar") {
                        publisher.saveConfig()
                        dismiss()
                    }.frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
