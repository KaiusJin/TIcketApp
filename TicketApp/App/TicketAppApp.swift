//
//  TicketAppApp.swift
//  TicketApp
//
//  Created by kaius on 2026-11-10.
//

import SwiftUI

@main
struct TicketAppApp: App {
    @State private var store: WalletStore
    @State private var processor: ReceiptCaptureModel

    init() {
        let store = WalletStore(repository: LocalWalletRepository())
        _store = State(initialValue: store)
        _processor = State(initialValue: ReceiptCaptureModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, processor: processor)
        }
    }
}
