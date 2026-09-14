//  ZonasSilencioView.swift
//
//  Lugares onde o carro comprovadamente fica sem rede — subsolo de garagem, por
//  exemplo. Lá o APK emudecer é o comportamento normal, e o bridge para de alertar
//  "App do carro silente" enquanto a última posição conhecida cair dentro da zona.
//
//  A coordenada usada é a do CARRO, não a do telefone: quem some é ele, e é a
//  posição dele que o alerta consulta. Marcar pelo telefone parece equivalente
//  quando o dono está do lado, mas erra quando ele marca de longe.

import SwiftUI

struct ZonasSilencioView: View {
    @State private var zonas: [Zona] = []
    @State private var carro: (lat: Double, lng: Double)?
    @State private var carregando = true
    @State private var erro: String?
    @State private var nome = ""
    @State private var salvando = false
    @State private var raio: Double = 250

    struct Zona: Identifiable {
        let id: String
        let name: String
        let lat: Double
        let lng: Double
        let radiusM: Int
        let dentro: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                explicacao
                if carregando {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    novaZona
                    if zonas.isEmpty {
                        Text("Nenhum local marcado.")
                            .font(.system(size: DS.FontSize.micro))
                            .foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(zonas.enumerated()), id: \.element.id) { i, z in
                                if i > 0 { Divider().background(DS.border) }
                                linhaZona(z)
                            }
                        }
                        .background(DS.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                if let e = erro {
                    Text(e).font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.red)
                }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .navigationTitle("Locais sem cobertura")
        .navigationBarTitleDisplayMode(.inline)
        .task { await carregar() }
    }

    private var explicacao: some View {
        Text("Nestes locais o carro fica sem rede e o app dele para de responder. "
             + "O alerta de “App do carro silente” fica suspenso enquanto a última "
             + "posição conhecida estiver dentro do raio.")
            .font(.system(size: DS.FontSize.micro))
            .foregroundStyle(DS.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var novaZona: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MARCAR ONDE O CARRO ESTÁ")
                .font(.system(size: DS.FontSize.micro, weight: .semibold))
                .foregroundStyle(DS.text2)
            TextField("Nome do local", text: $nome)
                .textFieldStyle(.plain)
                .font(.system(size: DS.FontSize.body))
                .foregroundStyle(DS.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(DS.panel)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            HStack {
                Text("Raio: \(Int(raio)) m")
                    .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.text2)
                Spacer()
                if let c = carro {
                    Text(String(format: "%.5f, %.5f", c.lat, c.lng))
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                }
            }
            Slider(value: $raio, in: 50...1000, step: 50).tint(DS.teal).frame(minHeight: 44)
            Button {
                Task { await criar() }
            } label: {
                HStack {
                    if salvando { ProgressView().tint(.black) }
                    Text(salvando ? "Salvando…" : "Marcar este local")
                        .font(.system(size: DS.FontSize.body, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(podeCriar ? DS.teal : DS.border)
                .foregroundStyle(podeCriar ? .black : DS.muted)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!podeCriar)
            // Sem coordenada do carro não há o que marcar — dizer o motivo evita o
            // botão morto sem explicação.
            if carro == nil {
                Text("Sem posição do carro agora — abra quando ele tiver reportado GPS.")
                    .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.orange)
            }
        }
    }

    private var podeCriar: Bool {
        !nome.trimmingCharacters(in: .whitespaces).isEmpty && carro != nil && !salvando
    }

    private func linhaZona(_ z: Zona) -> some View {
        HStack(spacing: 10) {
            Image(systemName: z.dentro ? "location.fill" : "mappin.and.ellipse")
                .foregroundStyle(z.dentro ? DS.green : DS.text2)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(z.name).font(.system(size: DS.FontSize.body, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(z.dentro ? "o carro está aqui agora · raio \(z.radiusM) m"
                              : "raio \(z.radiusM) m")
                    .font(.system(size: DS.FontSize.micro))
                    .foregroundStyle(z.dentro ? DS.green : DS.muted)
            }
            Spacer()
            Button {
                Task { await apagar(z) }
            } label: {
                Image(systemName: "trash").foregroundStyle(DS.red)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
    }

    // MARK: rede

    private func req(_ caminho: String, _ metodo: String, _ corpo: [String: Any]? = nil) -> URLRequest? {
        guard Settings.isConfigured, let url = URL(string: Settings.apiBase + caminho) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.httpMethod = metodo
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let c = corpo {
            r.addValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: c)
        }
        return r
    }

    private func carregar() async {
        carregando = true; erro = nil
        defer { carregando = false }
        guard let r = req("/api/silence-zones", "GET"),
              let (d, _) = try? await URLSession.shared.data(for: r),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            erro = "Não consegui falar com o bridge."; return
        }
        zonas = ((j["zones"] as? [[String: Any]]) ?? []).compactMap { z in
            guard let id = z["id"] as? String, let n = z["name"] as? String,
                  let la = z["lat"] as? Double, let lo = z["lng"] as? Double else { return nil }
            return Zona(id: id, name: n, lat: la, lng: lo,
                        radiusM: (z["radiusM"] as? Int) ?? 250,
                        dentro: (z["dentro"] as? Bool) ?? false)
        }
        if let c = j["carro"] as? [String: Any],
           let la = c["lat"] as? Double, let lo = c["lng"] as? Double, la != 0, lo != 0 {
            carro = (la, lo)
        } else { carro = nil }
    }

    private func criar() async {
        salvando = true; defer { salvando = false }
        // Sem lat/lng no corpo: o bridge usa a posição do carro, que é a fonte certa.
        guard let r = req("/api/silence-zones", "POST",
                          ["name": nome.trimmingCharacters(in: .whitespaces),
                           "radiusM": Int(raio)]),
              let (_, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            erro = "Não consegui salvar."; return
        }
        nome = ""
        await carregar()
    }

    private func apagar(_ z: Zona) async {
        guard let r = req("/api/silence-zones/" + z.id, "DELETE"),
              let _ = try? await URLSession.shared.data(for: r) else {
            erro = "Não consegui apagar."; return
        }
        await carregar()
    }
}
