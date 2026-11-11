import Foundation

/// Detects consecutive identical *complete* item objects across arbitrary streaming chunk boundaries.
/// It only requests review; repeated purchases are never deleted or silently merged.
nonisolated struct ReceiptOutputMonitor {
    private var depth = 0
    private var quoted = false
    private var escaped = false
    private var literal = ""
    private var rootString = ""
    private var itemsDepth: Int?
    private var itemBuffer: String?
    private var previousItem: Data?
    private(set) var repeatedItemRun = 0
    var shouldStop: Bool { repeatedItemRun >= 4 }

    mutating func append(_ delta: String) {
        for character in delta {
            itemBuffer?.append(character)
            if quoted {
                literal.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" {
                    quoted = false
                    if depth == 1 {
                        rootString = (try? JSONDecoder().decode(String.self, from: Data(literal.utf8))) ?? ""
                    }
                }
                continue
            }
            switch character {
            case "\"": quoted = true; literal = "\""
            case "{":
                if depth == itemsDepth { itemBuffer = "{" }
                depth += 1
            case "[":
                if depth == 1 && rootString == "items" {
                    itemsDepth = depth + 1
                    previousItem = nil
                    repeatedItemRun = 0
                }
                depth += 1
            case "}":
                depth -= 1
                if depth == itemsDepth, let buffer = itemBuffer {
                    if let item = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)),
                       let canonical = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) {
                        repeatedItemRun = canonical == previousItem ? repeatedItemRun + 1 : 1
                        previousItem = canonical
                    } else { previousItem = nil; repeatedItemRun = 0 }
                    itemBuffer = nil
                    if shouldStop { return }
                }
            case "]":
                if depth == itemsDepth { itemsDepth = nil }
                depth -= 1
            default: break
            }
        }
    }
}
