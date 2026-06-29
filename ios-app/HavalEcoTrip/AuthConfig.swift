//
//  AuthConfig.swift
//  Configuração do login federado (Google nativo).
//
//  Sign in with Apple não precisa de config aqui (é built-in via App ID).
//  Google nativo precisa de um OAuth client iOS criado no Google Cloud
//  (tipo iOS, bundle br.com.consorciolimpagyn.havalecotrip). Cole o Client ID
//  abaixo; o botão Google só aparece quando estiver preenchido.
//
//  ⚠️ Ao preencher, adicione TAMBÉM o "reversed client id" como URL scheme no
//  project.yml (CFBundleURLSchemes) — é o googleRedirectScheme abaixo.
//
import Foundation

enum AuthConfig {
    /// URL do porteiro (gateway) — a MESMA pra todo mundo. O login por email é que
    /// roteia cada pessoa pros dados dela. Ninguém precisa digitar URL/token.
    static let bridgeURL = "https://mqttrafael.duckdns.org:3443"

    /// Client ID do OAuth iOS do Google. Ex: "757576...-abc123.apps.googleusercontent.com".
    /// Vazio = login Google escondido no app.
    static let googleIOSClientID = "757576020219-bl2kofq49ksrpfgk4nt2g0k2qq00u7o6.apps.googleusercontent.com"

    static var googleEnabled: Bool { !googleIOSClientID.isEmpty }

    /// Scheme de callback = client id "invertido" (com.googleusercontent.apps.<sufixo>).
    static var googleRedirectScheme: String? {
        guard googleEnabled else { return nil }
        let suffix = googleIOSClientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps." + suffix
    }
}
