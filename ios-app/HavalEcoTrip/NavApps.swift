//
//  NavApps.swift
//  Abre um destino no app de navegação de verdade (Google Maps, Waze, Apple).
//
//  O Haval Hub calcula rota/ETA com o Google Directions e mostra os números,
//  mas NÃO guia — quem guia é o app do celular. Este helper faz a ponte.
//
//  Os schemes precisam estar em LSApplicationQueriesSchemes (project.yml), senão
//  canOpenURL sempre devolve false e o app some da lista mesmo instalado.
//

import Foundation
import UIKit

enum NavApp: String, CaseIterable, Identifiable {
    case googleMaps, waze, apple
    var id: String { rawValue }

    var label: String {
        switch self {
        case .googleMaps: return "Google Maps"
        case .waze:       return "Waze"
        case .apple:      return "Mapas"
        }
    }

    /// SF Symbol aproximado — os apps não expõem ícone pra uso externo.
    var icon: String {
        switch self {
        case .googleMaps: return "map.fill"
        case .waze:       return "car.fill"
        case .apple:      return "location.fill"
        }
    }

    /// Instalado? Apple Maps está sempre presente.
    var isInstalled: Bool {
        switch self {
        case .apple: return true
        case .googleMaps: return UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!)
        case .waze:       return UIApplication.shared.canOpenURL(URL(string: "waze://")!)
        }
    }

    /// URL de navegação guiada até o ponto.
    func url(lat: Double, lng: Double, name: String?) -> URL? {
        switch self {
        case .googleMaps:
            // App instalado usa o scheme; senão cai no site (abre no navegador).
            let native = "comgooglemaps://?daddr=\(lat),\(lng)&directionsmode=driving"
            if let u = URL(string: native), UIApplication.shared.canOpenURL(u) { return u }
            return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lng)&travelmode=driving")
        case .waze:
            return URL(string: "waze://?ll=\(lat),\(lng)&navigate=yes")
        case .apple:
            // `q=` só nomeia o pin; `dirflg=d` é o que abre em modo rota de carro.
            let q = (name ?? "Destino").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Destino"
            return URL(string: "http://maps.apple.com/?daddr=\(lat),\(lng)&q=\(q)&dirflg=d")
        }
    }

    /// Apps disponíveis pra oferecer, na ordem de preferência.
    static var available: [NavApp] { allCases.filter { $0.isInstalled } }
}

enum NavLauncher {
    /// Abre direto no app escolhido. Retorna false se a URL não pôde ser montada.
    @discardableResult
    static func open(_ app: NavApp, lat: Double, lng: Double, name: String? = nil) -> Bool {
        guard let u = app.url(lat: lat, lng: lng, name: name) else { return false }
        UIApplication.shared.open(u)
        return true
    }
}
