//
//  BydRecargaWidgetBundle.swift
//  Widget extension do app BYD Recarga — só a Live Activity do Song Pro.
//  Reusa SongProLiveActivity.swift + SongProActivityAttributes.swift (mesmos
//  arquivos do widget do app principal, via membership no project.yml).
//
import WidgetKit
import SwiftUI

@main
struct BydRecargaWidgetBundle: WidgetBundle {
    var body: some Widget {
        SongProLiveActivity()
        SongProTripLiveActivity()
        CompanionInboundLiveActivity()   // feature 1: companion indo até a Grasi
        BydChargeWidget()
    }
}
