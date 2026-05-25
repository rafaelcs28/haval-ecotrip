//
//  HavalEcoTripApp.swift
//  Entry point do app companion iOS. App em si é minimalíssimo — toda a UX
//  acontece na Live Activity (lock screen + Dynamic Island). O app só serve
//  pra registrar o pushToken da activity no bridge.
//
import SwiftUI

@main
struct HavalEcoTripApp: App {
    init() {
        // Migra URL/token de versões antigas (UserDefaults.standard) pro
        // App Group novo — sem isso o widget aparece vazio e o user precisa
        // re-colar tudo. Idempotente.
        Settings.migrateFromStandardIfNeeded()
        // Registra handler de BG refresh ANTES de qualquer view aparecer.
        // Sem isso, iOS não acorda o app em background pra polling de notifs.
        BackgroundRefresh.register()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
