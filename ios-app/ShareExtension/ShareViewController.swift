//  ShareViewController.swift
//  Share Extension: receber um destino do Waze/Maps (link/texto) e mandar pro carro.
//  Lê o item compartilhado → POST /api/share-dest no bridge (bridge resolve a
//  coordenada, publica pro Ecotrip e nomeia a viagem) → confirma e fecha.

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.text = "Enviando destino ao carro…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        extractText { [weak self] text in
            guard let self else { return }
            guard let text, !text.isEmpty else { self.finish("Nada pra enviar"); return }
            self.send(text)
        }
    }

    /// Extrai o texto/URL compartilhado dos anexos do item.
    private func extractText(_ done: @escaping (String?) -> Void) {
        guard let item = (extensionContext?.inputItems.first as? NSExtensionItem),
              let providers = item.attachments else { done(nil); return }
        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        // Tenta URL primeiro (Maps/Waze compartilham link), depois texto puro.
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            p.loadItem(forTypeIdentifier: urlType, options: nil) { obj, _ in
                let s = (obj as? URL)?.absoluteString ?? (obj as? String)
                DispatchQueue.main.async { done(s ?? (item.attributedContentText?.string)) }
            }
        } else if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            p.loadItem(forTypeIdentifier: textType, options: nil) { obj, _ in
                DispatchQueue.main.async { done((obj as? String) ?? item.attributedContentText?.string) }
            }
        } else {
            done(item.attributedContentText?.string)
        }
    }

    private func send(_ text: String) {
        let baseRaw = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        let base = baseRaw.hasSuffix("/") ? String(baseRaw.dropLast()) : baseRaw
        guard !base.isEmpty, let url = URL(string: "\(base)/api/share-dest") else {
            finish("Configure o app primeiro"); return
        }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 20
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        URLSession.shared.dataTask(with: r) { [weak self] data, resp, _ in
            var msg = "Não consegui o destino"
            if let code = (resp as? HTTPURLResponse)?.statusCode, code == 200,
               let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               (j["ok"] as? Bool) == true {
                let name = (j["name"] as? String) ?? ""
                msg = name.isEmpty ? "Destino enviado ✓" : "No carro ✓\n\(name)"
            }
            DispatchQueue.main.async { self?.finish(msg) }
        }.resume()
    }

    private func finish(_ message: String) {
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
