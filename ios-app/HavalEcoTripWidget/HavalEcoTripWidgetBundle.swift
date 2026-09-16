//
//  HavalEcoTripWidgetBundle.swift
//  Bundle do Widget Extension: Live Activities + widgets de home/lock screen.
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
        InfraLiveActivity()
        ParkingLiveActivity()
        BatteryWidget()
        LockBatteryWidget()
        if #available(iOS 17.0, *) { ControlsWidget() }
        DepartureAskLiveActivity()
        MonitorWidget()
        LockMonitorWidget()
    }
}
