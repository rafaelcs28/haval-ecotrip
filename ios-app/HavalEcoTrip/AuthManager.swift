//
//  AuthManager.swift
//  Login NATIVO no app (Sign in with Apple + Google), porque o botão federado
//  embutido na PWA não funciona dentro do WKWebView (Google bloqueia OAuth em
//  webview). Fluxo:
//    1. login nativo → ID token (Apple) ou id_token via OAuth/PKCE (Google)
//    2. POST <base>/gw/{apple,google}  (porteiro verifica + roteia por email)
//    3. recebe { token } + cookie de sessão `etenant`
//    4. guarda o token (Settings) e injeta o cookie no WKWebView → carrega a URL
//
//  Fallback: se /gw/* não existir (acesso direto ao bridge, sem porteiro),
//  tenta /api/auth/{apple,google}/login (single-tenant, sem cookie de rota).
//
import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import WebKit

@MainActor
final class AuthManager: NSObject, ObservableObject {
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var needsTotp = false        // backend pediu 2FA

    var onSuccess: (() -> Void)?

    private var base = ""
    private var pendingPath = ""
    private var pendingCredential = ""
    private var webAuthSession: ASWebAuthenticationSession?

    private func cleanBase(_ s: String) -> String {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    // MARK: - Apple (a view usa SignInWithAppleButton e entrega o resultado aqui)
    func handleAppleResult(_ result: Result<ASAuthorization, Error>, base: String) {
        self.base = cleanBase(base)
        guard !self.base.isEmpty else { errorMessage = "Configure a URL primeiro."; return }
        switch result {
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = cred.identityToken,
                  let token = String(data: data, encoding: .utf8) else {
                errorMessage = "Apple: token de identidade ausente."; return
            }
            busy = true; errorMessage = nil
            Task { await postCredential(path: "/gw/apple", credential: token) }
        case .failure(let err):
            if (err as? ASAuthorizationError)?.code != .canceled {
                errorMessage = "Apple: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - Google (ASWebAuthenticationSession + PKCE, no navegador do sistema)
    func startGoogle(base: String) {
        self.base = cleanBase(base)
        guard !self.base.isEmpty else { errorMessage = "Configure a URL primeiro."; return }
        guard AuthConfig.googleEnabled, let scheme = AuthConfig.googleRedirectScheme else {
            errorMessage = "Login Google ainda não configurado."; return
        }
        errorMessage = nil; busy = true
        let verifier  = Self.randomURLSafe(48)
        let challenge = Self.codeChallenge(verifier)
        let redirect  = scheme + ":/oauth2redirect"
        var comp = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comp.queryItems = [
            .init(name: "client_id",             value: AuthConfig.googleIOSClientID),
            .init(name: "redirect_uri",          value: redirect),
            .init(name: "response_type",         value: "code"),
            .init(name: "scope",                 value: "openid email"),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let session = ASWebAuthenticationSession(url: comp.url!, callbackURLScheme: scheme) { [weak self] callback, err in
            guard let self else { return }
            Task { @MainActor in
                guard let callback, err == nil else {
                    self.busy = false
                    if (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.errorMessage = "Login Google cancelado."
                    }
                    return
                }
                let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
                guard let code else { self.busy = false; self.errorMessage = "Google: sem código."; return }
                await self.exchangeGoogleCode(code, verifier: verifier, redirect: redirect)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        session.start()
    }

    private func exchangeGoogleCode(_ code: String, verifier: String, redirect: String) async {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id":     AuthConfig.googleIOSClientID,
            "code":          code,
            "code_verifier": verifier,
            "grant_type":    "authorization_code",
            "redirect_uri":  redirect,
        ].map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&")
        req.httpBody = form.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let idToken = obj?["id_token"] as? String else {
                busy = false; errorMessage = "Google: sem id_token."; return
            }
            await postCredential(path: "/gw/google", credential: idToken)
        } catch {
            busy = false; errorMessage = "Falha Google: \(error.localizedDescription)"
        }
    }

    // MARK: - 2FA
    func submitTotp(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard c.count >= 6 else { errorMessage = "Digite os 6 dígitos."; return }
        busy = true
        Task { await postCredential(path: pendingPath, credential: pendingCredential, totp: c) }
    }

    // MARK: - Envio ao porteiro/bridge
    private func directFallback(_ path: String) -> String {
        switch path {
        case "/gw/apple":  return "/api/auth/apple/login"
        case "/gw/google": return "/api/auth/google/login"
        default:           return path
        }
    }

    private func postCredential(path: String, credential: String, totp: String? = nil, allowFallback: Bool = true) async {
        pendingPath = path; pendingCredential = credential
        guard let url = URL(string: base + path) else { busy = false; errorMessage = "URL inválida."; return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["credential": credential]
        if let totp { payload["totp_code"] = totp }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            // Sem porteiro → tenta o endpoint direto do bridge uma vez.
            if http?.statusCode == 404, allowFallback, path.hasPrefix("/gw/") {
                await postCredential(path: directFallback(path), credential: credential, totp: totp, allowFallback: false)
                return
            }
            let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            if http?.statusCode == 200, obj["ok"] as? Bool == true, let token = obj["token"] as? String {
                finishSuccess(token: token, http: http, url: url)
            } else if (obj["error"] as? String) == "totp_required" || (obj["requires_2fa"] as? Bool) == true {
                needsTotp = true; busy = false
            } else {
                busy = false
                let e = obj["error"] as? String ?? "HTTP \(http?.statusCode ?? 0)"
                errorMessage = (e == "email_not_allowed") ? "Conta não autorizada." :
                               (e == "invalid_totp") ? "Código inválido." : "Falha no login: \(e)"
            }
        } catch {
            busy = false; errorMessage = "Rede: \(error.localizedDescription)"
        }
    }

    private func finishSuccess(token: String, http: HTTPURLResponse?, url: URL) {
        Settings.bridgeURL = base
        Settings.bridgeToken = token
        needsTotp = false; errorMessage = nil
        // Injeta o cookie de sessão (etenant) no cookie store do WKWebView, pra
        // que o webview seja roteado/autenticado ao carregar a URL do porteiro.
        if let fields = http?.allHeaderFields as? [String: String] {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !cookies.isEmpty {
                let store = WKWebsiteDataStore.default().httpCookieStore
                let group = DispatchGroup()
                for c in cookies { group.enter(); store.setCookie(c) { group.leave() } }
                group.notify(queue: .main) { self.busy = false; self.onSuccess?() }
                return
            }
        }
        busy = false; onSuccess?()
    }

    // MARK: - Helpers PKCE
    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64url(Data(bytes))
    }
    private static func codeChallenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

extension AuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
