import SwiftUI

struct WalletDateButton: View {
    let title: String
    @Binding var selection: Date
    var bounds: ClosedRange<Date> = Date.distantPast...Date.distantFuture
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            Text(WalletDate.day(selection)).padding(.horizontal, 10).frame(minHeight: 44)
                .contentShape(.rect(cornerRadius: 12))
        }
        .accessibilityLabel(title).accessibilityValue(WalletDate.day(selection))
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                DatePicker(title, selection: $selection, in: bounds, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.calendar, WalletDate.calendar)
                    .walletPage().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPicker = false } } }
            }.presentationDetents([.medium, .large])
        }
    }
}

struct WalletMonthPicker: View {
    let initialDate: Date
    let earliestDate: Date
    let select: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var month: Int

    init(initialDate: Date, earliestDate: Date, select: @escaping (Date) -> Void) {
        self.initialDate = initialDate
        self.earliestDate = earliestDate
        self.select = select
        _year = State(initialValue: WalletDate.calendar.component(.year, from: initialDate))
        _month = State(initialValue: WalletDate.calendar.component(.month, from: initialDate))
    }

    private var selectedDate: Date {
        WalletDate.calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Month", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(WalletDate.calendar.shortMonthSymbols[value - 1]).tag(value)
                    }
                }
                Picker("Year", selection: $year) {
                    ForEach(min(1900, WalletDate.calendar.component(.year, from: earliestDate))...WalletDate.calendar.component(.year, from: .now), id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
            }.environment(\.locale, Locale(identifier: "en_US"))
                .scrollContentBackground(.hidden).walletPage()
                .navigationTitle("Choose month").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { select(selectedDate); dismiss() }.disabled(selectedDate > Date())
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}
