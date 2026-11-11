import SwiftUI

struct WalletSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wallet.appearance") private var appearance = "system"
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
            }.scrollContentBackground(.hidden).walletPage().navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
