//  ParkingStore.swift
//  "Onde estacionei": guarda o local do carro quando ele desliga (transição
//  motor ligado→desligado) e persiste pra te levar de volta depois. O ponto é
//  a última posição GPS do carro no momento de desligar.

import Foundation
import CoreLocation

struct ParkingSpot: Codable, Equatable {
    var lat: Double
    var lng: Double
    var ts: Double
    var note: String = ""
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

@MainActor
final class ParkingStore: ObservableObject {
    static let shared = ParkingStore()
    @Published private(set) var spot: ParkingSpot?

    private var lastEngineOn: Bool?
    private let key = "parking_spot"
    private var def: UserDefaults { UserDefaults(suiteName: "group.br.com.consorciolimpagyn.havalecotrip") ?? .standard }

    init() {
        if let d = def.data(forKey: key), let s = try? JSONDecoder().decode(ParkingSpot.self, from: d) { spot = s }
    }
    private func persist() {
        if let s = spot, let d = try? JSONEncoder().encode(s) { def.set(d, forKey: key) }
    }

    /// Chamado a cada atualização de estado do carro (CarStore).
    func onCarUpdate(engineOn: Bool, lat: Double, lng: Double) {
        defer { lastEngineOn = engineOn }
        let hasGps = lat != 0 || lng != 0
        // Acabou de desligar (ligado → desligado) e tem GPS → registra o ponto.
        if lastEngineOn == true, !engineOn, hasGps { save(lat: lat, lng: lng) }
    }

    private func save(lat: Double, lng: Double) {
        // Preserva a nota se for praticamente o mesmo lugar (<40 m).
        var note = ""
        if let s = spot,
           CLLocation(latitude: s.lat, longitude: s.lng)
            .distance(from: CLLocation(latitude: lat, longitude: lng)) < 40 { note = s.note }
        spot = ParkingSpot(lat: lat, lng: lng, ts: Date().timeIntervalSince1970, note: note)
        persist()
    }

    /// Salva manualmente a posição atual do carro como local de estacionamento.
    func saveCurrent(lat: Double, lng: Double) {
        guard lat != 0 || lng != 0 else { return }
        save(lat: lat, lng: lng)
    }

    func setNote(_ n: String) {
        guard var s = spot else { return }
        s.note = String(n.prefix(80)); spot = s; persist()
    }

    func clear() { spot = nil; def.removeObject(forKey: key) }
}
