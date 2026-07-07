//
//  ParkingLiveActivity.swift
//  Live Activity "voltar ao carro" (lock screen + Dynamic Island). Mostra a
//  distância até o Haval estacionado + seta apontando o rumo geográfico (relativo
//  ao Norte) e um rótulo cardinal. Toque abre rota a pé no Apple Maps.
//
import ActivityKit
import SwiftUI
import WidgetKit

struct ParkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingActivityAttributes.self) { context in
            ParkingLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(LAv2.bg)
                .activitySystemActionForegroundColor(LAv2.blue)
                .widgetURL(context.state.mapsURL)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ParkingArrow(bearing: s.bearingDeg, size: 22)
                        .frame(width: 40, height: 40)
                        .background(LAv2.blue.opacity(0.15), in: Circle())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Carro a \(s.distLabel)")
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(LAv2.blue)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        (Text(s.note.isEmpty ? "\(cardinal(s.bearingDeg)) · estac. há " : "\(s.note) · ") + Text(s.parkedAt, style: .relative))
                            .font(.system(size: 11)).foregroundStyle(LAv2.text2)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Link(destination: s.mapsURL) {
                            HStack(spacing: 5) {
                                Image(systemName: "map.fill").font(.system(size: 12, weight: .bold))
                                Text("Rota").font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(LAv2.blue, in: Capsule())
                        }
                        if #available(iOS 17.0, *) {
                            LAActionButton(title: "Piscar", systemImage: "light.beacon.max.fill",
                                           tint: LAv2.blue, intent: FindCarIntent())
                        }
                    }
                }
            } compactLeading: {
                ParkingArrow(bearing: s.bearingDeg, size: 15)
            } compactTrailing: {
                Text(s.distLabel)
                    .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(LAv2.blue)
                    .frame(maxWidth: 52)
                    .lineLimit(1).minimumScaleFactor(0.5)
            } minimal: {
                ParkingArrow(bearing: s.bearingDeg, size: 15)
            }
            .keylineTint(LAv2.blue)
        }
    }
}

// MARK: - Lock screen

struct ParkingLockScreenView: View {
    let state: ParkingActivityAttributes.ContentState
    let carName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "parkingsign")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(LAv2.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(carName)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(LAv2.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text("VOLTAR AO CARRO")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(LAv2.blue)
            }
            HStack(alignment: .center, spacing: 14) {
                ParkingArrow(bearing: state.bearingDeg, size: 34)
                    .frame(width: 58, height: 58)
                    .background(LAv2.blue.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(state.distLabel)
                            .font(.system(size: 26, weight: .light)).tracking(-0.5)
                            .monospacedDigit().foregroundStyle(LAv2.blue)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("· \(cardinal(state.bearingDeg))")
                            .font(.system(size: 12)).foregroundStyle(LAv2.text2)
                    }
                    (Text("Estacionado há ") + Text(state.parkedAt, style: .relative))
                        .font(.system(size: 11.5)).foregroundStyle(LAv2.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if !state.note.isEmpty {
                        Label(state.note, systemImage: "mappin.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LAv2.blue)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 8)
                Link(destination: state.mapsURL) {
                    VStack(spacing: 3) {
                        Image(systemName: "map.fill").font(.system(size: 14, weight: .bold))
                        Text("Rota").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(LAv2.blue, in: Capsule())
                }
            }
            VStack(spacing: 8) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                HStack(spacing: 10) {
                    if #available(iOS 17.0, *) {
                        LAActionButton(title: "Piscar faróis", systemImage: "light.beacon.max.fill",
                                       tint: LAv2.blue, intent: FindCarIntent())
                    } else {
                        Text("Toque pra abrir a rota a pé")
                            .font(.system(size: 10.5)).foregroundStyle(LAv2.text2)
                    }
                    Spacer(minLength: 6)
                    Text(state.updatedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(LAv2.muted)
                }
            }
        }
        .padding(14)
        .background(alignment: .topLeading) {
            RadialGradient(colors: [LAv2.blue.opacity(0.14), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 220)
        }
    }
}

// Seta apontando o rumo (0°=Norte=cima). Geográfica: útil com o topo do telefone
// voltado ao Norte — o rótulo cardinal ajuda a orientar sem bússola ao vivo.
struct ParkingArrow: View {
    let bearing: Int
    let size: CGFloat
    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(LAv2.blue)
            .rotationEffect(.degrees(Double(bearing)))
    }
}

// Rumo em graus → rótulo cardinal PT-BR.
func cardinal(_ deg: Int) -> String {
    let dirs = ["N", "NE", "L", "SE", "S", "SO", "O", "NO"]
    let i = Int((Double(deg).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
    return dirs[(i + 8) % 8]
}
