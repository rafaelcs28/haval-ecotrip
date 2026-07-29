//
//  DepartureAskLiveActivity.swift
//  Visual + intents da LA "Indo pra X? Compartilhar?". iOS 17+ pra botões
//  nativos (LiveActivityIntent). Não abre app pra confirmar — 1 tap resolve.
//
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let askAccent = Color(red: 0.30, green: 0.80, blue: 0.95)   // ciano (mesma família SharedTrip)

// MARK: - Intents (LiveActivityIntent = executa NO SISTEMA sem abrir app)

@available(iOS 17.0, *)
struct DepartureAcceptIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Sim, compartilhar"
    @Parameter(title: "configId") var configId: String
    init() {}
    init(configId: String) { self.configId = configId }
    func perform() async throws -> some IntentResult {
        let ok = await CarIntentAPI.departureAccept(configId: configId)
        // Encerra a LA correspondente e atualiza pra "acted".
        await DepartureAskLifecycle.end(configId: configId,
                                        status: ok ? "acted_accept" : "acted_dismiss",
                                        message: ok ? "Destino setado + share pra Grasi criado" : "Falhou — tenta manual")
        return .result()
    }
}

@available(iOS 17.0, *)
struct DepartureDismissIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Não hoje"
    @Parameter(title: "configId") var configId: String
    init() {}
    init(configId: String) { self.configId = configId }
    func perform() async throws -> some IntentResult {
        await CarIntentAPI.departureDismiss(configId: configId)
        await DepartureAskLifecycle.end(configId: configId, status: "acted_dismiss", message: nil)
        return .result()
    }
}

@available(iOS 17.0, *)
/// "Na próxima partida" — não é adiamento por tempo, é por EVENTO.
///
/// Caso real: ligar o carro só pra manobrar no pátio da empresa. Não é a saída,
/// mas a pergunta já apareceu. Adiar 5 min não servia: se a manobra durasse mais
/// que isso a pergunta voltava no meio dela, e se a saída real fosse duas horas
/// depois já tinha passado.
///
/// O bridge apaga a marca do dia, e como `_evalDepartureAsk` roda a cada engine
/// on, a pergunta volta exatamente quando o carro for ligado de novo.
struct DepartureSnoozeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Perguntar na próxima partida"
    @Parameter(title: "configId") var configId: String
    init() {}
    init(configId: String) { self.configId = configId }
    func perform() async throws -> some IntentResult {
        // 1. Bridge: apaga a marca do dia (libera o push-to-start).
        await CarIntentAPI.departureSnooze(configId: configId)
        // 2. App: a LA também pode nascer pelo DepartureAskManager local, que tem
        //    marca própria no App Group. Sem limpar as duas, o caminho local
        //    continuaria bloqueado hoje e o "próxima partida" só valeria pra metade
        //    dos casos. E NÃO gravamos departure_snooze_: aquela chave é o
        //    adiamento por tempo, que suprimiria a pergunta que queremos de volta.
        DepartureAskLifecycle.limparMarcaLocalDeHoje(configId: configId)
        // 3. Encerra a LA atual: quem recria é o próximo engine on.
        await DepartureAskLifecycle.end(configId: configId, status: "acted_snooze",
                                        message: "Pergunto na próxima partida")
        return .result()
    }
}

// MARK: - Lifecycle helper (compartilhado — chamado pelos intents)

/// Fecha a Activity daquela config (dispara `Activity.end`) e persiste o
/// snooze no App Group pra o manager respeitar. Só o app tem ownership da
/// Activity; intents em widget target usam este mesmo helper via target
/// membership do arquivo.
@available(iOS 17.0, *)
enum DepartureAskLifecycle {
    static func end(configId: String, status: String, message: String?) async {
        for activity in Activity<DepartureAskActivityAttributes>.activities where activity.attributes.configId == configId {
            var cs = activity.content.state
            cs.status = status
            cs.resultText = message
            await activity.end(ActivityContent(state: cs, staleDate: Date().addingTimeInterval(30)),
                               dismissalPolicy: .after(Date().addingTimeInterval(6)))
        }
    }
    /// Apaga a marca "já perguntei hoje" que o DepartureAskManager grava no App
    /// Group, pra a pergunta poder voltar no próximo engine on. Espelha a mesma
    /// limpeza que o bridge faz em /api/departure/snooze — as duas camadas criam
    /// LA, então as duas precisam liberar.
    static func limparMarcaLocalDeHoje(configId: String) {
        guard let d = UserDefaults(suiteName: "group.br.com.consorciolimpagyn.havalecotrip") else { return }
        let now = Date()
        let cal = Calendar.current
        let y = cal.component(.year, from: now), m = cal.component(.month, from: now), dd = cal.component(.day, from: now)
        let today = String(format: "%04d-%02d-%02d", y, m, dd)
        d.removeObject(forKey: "departure_asked_\(configId)_\(today)")
        // Limpa também um adiamento por tempo pendente: ele suprimiria a pergunta
        // que acabamos de pedir de volta.
        d.removeObject(forKey: "departure_snooze_\(configId)")
    }

    /// Adiamento por TEMPO. Mantido porque a chave é lida pelo manager, mas hoje
    /// nenhum botão o usa — "Depois" virou por evento (próxima partida), que é o
    /// que resolve o caso de manobrar o carro sem sair.
    static func snooze(configId: String, minutes: Int) async {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if let d = UserDefaults(suiteName: "group.br.com.consorciolimpagyn.havalecotrip") {
            d.set(until.timeIntervalSince1970, forKey: "departure_snooze_\(configId)")
        }
        await end(configId: configId, status: "acted_snooze", message: "Adiado \(minutes) min")
    }
}

// MARK: - View

// IMPORTANTE: Widget struct NÃO pode ter @available(iOS 17.0, *) — isso deixa
// o tipo de Activity "conditional" e o iOS não emite pushToStartTokenUpdates
// pra ele. Os botões (Button(intent:)) são iOS 17+ e vão wrappados
// individualmente dentro da view. Isso permite o widget registrar em iOS 16.1+
// e ter botões só no 17+.
struct DepartureAskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DepartureAskActivityAttributes.self) { context in
            DepartureAskLockScreenView(state: context.state, attrs: context.attributes)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(askAccent)
        } dynamicIsland: { context in
            let a = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "car.side.and.exclamationmark").foregroundStyle(askAccent).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(a.destName).font(.headline).foregroundStyle(askAccent).lineLimit(1).minimumScaleFactor(0.6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.status == "asking" {
                        if #available(iOS 17.0, *) {
                            HStack(spacing: 8) {
                                Button(intent: DepartureAcceptIntent(configId: a.configId)) {
                                    Label("Sim", systemImage: "checkmark.circle.fill")
                                }.buttonStyle(.borderedProminent).tint(.green)
                                Button(intent: DepartureSnoozeIntent(configId: a.configId)) {
                                    Label("Depois", systemImage: "arrow.clockwise")
                                }.buttonStyle(.bordered).tint(.orange)
                                Button(intent: DepartureDismissIntent(configId: a.configId)) {
                                    Label("Não", systemImage: "xmark.circle")
                                }.buttonStyle(.bordered).tint(.gray)
                            }
                        } else {
                            Text("Toque na LA pra decidir").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(context.state.resultText ?? "OK").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "car.side.and.exclamationmark").foregroundStyle(askAccent)
            } compactTrailing: {
                Text(a.destName).font(.caption).bold().foregroundStyle(askAccent).lineLimit(1)
            } minimal: {
                Image(systemName: "car.side.and.exclamationmark").foregroundStyle(askAccent)
            }.keylineTint(askAccent)
        }
    }
}

struct DepartureAskLockScreenView: View {
    let state: DepartureAskActivityAttributes.ContentState
    let attrs: DepartureAskActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "car.side.and.exclamationmark").foregroundStyle(askAccent)
                Text("Saindo de \(attrs.sourceName)").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Indo pra \(attrs.destName)?")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(askAccent)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("Compartilhar trajeto com \(attrs.subject) no Grasi Recarga?")
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(2)
            if state.status == "asking" {
                if #available(iOS 17.0, *) {
                    HStack(spacing: 8) {
                        Button(intent: DepartureAcceptIntent(configId: attrs.configId)) {
                            Label("Sim", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.green)
                        Button(intent: DepartureSnoozeIntent(configId: attrs.configId)) {
                            Label("Depois", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).tint(.orange)
                        Button(intent: DepartureDismissIntent(configId: attrs.configId)) {
                            Label("Não", systemImage: "xmark").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).tint(.gray)
                    }
                } else {
                    Text("Abre o app pra decidir").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(state.resultText ?? "OK").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .padding(14)
    }
}
