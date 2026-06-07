//
//  HavalEcoTripWidgetBundle.swift
//  Bundle do Widget Extension. Por enquanto só hospeda a Live Activity de
//  recarga; pode ganhar widgets de home screen no futuro.
//
import SwiftUI
import WidgetKit

@main
struct HavalEcoTripWidgetBundle: WidgetBundle {
    var body: some Widget {
        ChargeActivityLiveActivity()
        PreClimatLiveActivity()
        TripLiveActivity()
        MotorLiveActivity()
        SecurityLiveActivity()
        BatteryWidget()
        LockBatteryWidget()
        if #available(iOS 17.0, *) { ControlsWidget() }
    }
}
