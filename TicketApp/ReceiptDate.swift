import Foundation

/// Validates dates emitted by the receipt JSON model.
nonisolated enum ReceiptDate {
    static func isValidDate(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              value.count == 10 else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]) else { return false }
        let year = parts[0]
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[parts[1] - 1]).contains(parts[2])
    }
}
