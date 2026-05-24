//
//  HavalEcoTripApp.swift
//  Entry point do app companion iOS. App em si é minimalíssimo — toda a UX
//  acontece na Live Activity (lock screen + Dynamic Island). O app só serve
//  pra registrar o pushToken da activity no bridge.
//
import SwiftUI

@main
struct HavalEcoTripApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
