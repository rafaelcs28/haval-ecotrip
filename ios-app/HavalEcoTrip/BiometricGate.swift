//
//  BiometricGate.swift
//  Bloqueio do app com Face ID (toggle em Configurações). Trava ao ir pra
//  background; pede biometria ao voltar.
//

import SwiftUI
import LocalAuthentication

struct BiometricGate: View {
    @AppStorage("faceid_lock") private var enabled = false
    @State private var unlocked = false
    @State private var prompting = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if enabled && !unlocked {
                ZStack {
                    DS.bg.ignoresSafeArea()
                    VStack(spacing: 18) {
                        Image(systemName: "faceid").font(.system(size: 60)).foregroundStyle(DS.green)
                        Text("App bloqueado").font(.headline).foregroundStyle(DS.text)
                        Button { authenticate() } label: {
                            Text("Desbloquear").font(.system(size: 16, weight: .bold))
                                .frame(width: 200, height: 50).foregroundStyle(.black)
                                .background(DS.green).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .onAppear { if !prompting { authenticate() } }
            }
        }
        .onChange(of: phase) { _, p in
            if p == .background { unlocked = false }
            else if p == .active && enabled && !unlocked { authenticate() }
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { unlocked = true; return }
        prompting = true
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloquear o Haval EcoTrip") { ok, _ in
            DispatchQueue.main.async { prompting = false; if ok { unlocked = true } }
        }
    }
}
