import Foundation
import AppKit

func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    print("PASS: \(message)")
}
func fragment(_ text: String, x: Double, y: Double, width: Double = 0.2,
              regions: [OCRLine.TextRegion]? = nil) -> OCRLine {
    .init(candidates: [.init(text: text, confidence: 0.95)], x: x, y: y, width: width, height: 0.02,
          amountRegions: regions)
}
func receipt(left: Double = 0.1, scale: Double = 1, dual: Bool = false) -> OCRScan {
    var observations: [OCRLine] = []
    for (i, amount) in ["1.29", "12.34", "123.45", "-0.50", "1,25", "137.83"].enumerated() {
        let y = 0.9 - Double(i) * 0.05
        let width = Double(amount.count) * 0.018 * scale
        observations.append(fragment(i == 5 ? "TOTAL" : "Item 2% 1.5L", x: left, y: y, width: 0.3 * scale))
        observations.append(fragment(amount, x: left + 0.8 * scale - width, y: y + 0.002, width: width))
        if dual { observations.append(fragment("0.99", x: left + 0.52 * scale, y: y, width: 0.08 * scale)) }
    }
    return OCRScan(observations: observations)
}
func checkCoverage(_ scan: OCRScan) {
    expect(scan.priceLayout.blocks.flatMap(\.rowIndices) == Array(scan.rows.indices), "All rows covered exactly once in order")
    let restored = scan.itemText.replacingOccurrences(of: "[price-column]", with: "")
        .replacingOccurrences(of: "[/price-column]", with: "").replacingOccurrences(of: "\n\n", with: "\n")
    expect(restored == scan.text, "Layout hints preserve all original text and duplicates")
}

let basic = receipt()
expect(basic.priceLayout.columns.count == 1 && basic.priceLayout.columns[0].anchors.count == 6,
       "Right edges identify one column despite different price widths, signs and decimal separators")
expect(basic.priceLayout.blocks.count == 2, "Neighboring priced rows form small soft blocks")
expect(basic.itemText.contains("Item 2% 1.5L [price-column]1.29[/price-column]"), "Specifications stay in description; amount is marked separately")
expect(basic.itemText.contains("TOTAL [price-column]137.83[/price-column]"), "Totals are retained as candidates without assigning item semantics")
checkCoverage(basic)
let moved = receipt(left: 0.35, scale: 0.5)
expect(abs(moved.priceLayout.columns[0].rightEdge - 0.75) < 1e-9, "Column adapts to receipt scale and image margins")
expect(moved.itemText == basic.itemText, "Layout hints are invariant under horizontal scaling and translation")
let dual = receipt(dual: true)
expect(dual.priceLayout.columns.count == 2 && dual.priceLayout.primaryColumnIndex == 1, "Multiple columns retained; rightmost used only as a grouping cue")
checkCoverage(dual)
let reversed = OCRScan(observations: basic.observations.reversed())
expect(reversed.itemText == basic.itemText, "Vision observation order does not change layout hints")

let weak = OCRScan(observations: Array(basic.observations.prefix(4)))
expect(weak.priceLayout.columns.isEmpty && weak.itemText == weak.text, "Insufficient repeated evidence falls back to unchanged OCR")
let empty = OCRScan(observations: [])
expect(empty.itemText.isEmpty && empty.priceLayout.blocks.isEmpty, "Empty scan has no fabricated evidence")
let numbers = OCRScan(observations: (0..<4).map { fragment("12.34", x: 0.8, y: 0.8 - Double($0) * 0.05, width: 0.1) })
expect(numbers.priceLayout.columns.isEmpty, "Numeric lists alone do not establish a price column")
let unaligned = OCRScan(observations: basic.observations + [fragment("9.99", x: 0.65, y: 0.4, width: 0.08)])
expect(!unaligned.itemText.contains("[price-column]9.99"), "Unaligned amount remains untouched")
for text in ["2%", "1.50L", "SKU12.34", "500g", "123456789", "12.34%", "1.234 kg"] {
    expect(OCRPriceLayout.amountRanges(in: text).isEmpty, "Not a price token: \(text)")
}
for text in ["$ 12.34", "€12,34", "-1.25", "1.25-", "1,234.56", "1.234,56", "$12", "12.34 €"] {
    expect(OCRPriceLayout.amountRanges(in: text) == [NSRange(text.startIndex..., in: text)], "Preserve printed money token: \(text)")
}

// Names can precede or follow the row bearing the price. Neither side is cut
// off just to satisfy a target block size, including a detached price-only row.
let multiline = OCRScan(observations: basic.observations + [
    fragment("continued name", x: 0.12, y: 0.775),
    fragment("0.500 kg @ 6.50", x: 0.12, y: 0.725, width: 0.35),
    fragment("long name before price", x: 0.12, y: 0.625, width: 0.35),
    fragment("3.25", x: 0.828, y: 0.60, width: 0.072)
])
func blockContaining(_ text: String) -> Int? {
    multiline.priceLayout.blocks.firstIndex { block in block.rowIndices.contains { multiline.rows[$0].text == text } }
}
expect(blockContaining("continued name") == blockContaining("Item 2% 1.5L 123.45")
       && blockContaining("continued name") == blockContaining("Item 2% 1.5L -0.50"), "Ambiguous continuation keeps both neighboring priced rows together")
expect(blockContaining("long name before price") == blockContaining("3.25"), "Price-only row remains with preceding description")
checkCoverage(multiline)

// One Vision observation may contain the whole row. Only exact substring boxes
// justify separating money; string-length interpolation is never used.
let combined = OCRScan(observations: (0..<4).map { i in
    let text = "牛奶 🥛 1.5L  12.34"
    let range = (text as NSString).range(of: "12.34")
    return fragment(text, x: 0.1, y: 0.9 - Double(i) * 0.05, width: 0.8,
                    regions: [.init(location: range.location, length: range.length, x: 0.8,
                                    y: 0.9 - Double(i) * 0.05, width: 0.1, height: 0.02)])
})
expect(combined.itemText.contains("牛奶 🥛 1.5L  [price-column]12.34[/price-column]"), "Exact UTF-16 substring geometry separates merged rows without losing Unicode names")
checkCoverage(combined)
let noRegions = OCRScan(observations: combined.observations.map { fragment($0.text, x: $0.x, y: $0.y, width: $0.width) })
expect(noRegions.itemText == noRegions.text, "Missing substring geometry does not fabricate a price position")
let decoded = try JSONDecoder().decode(OCRScan.self, from: Data(combined.evidenceJSON().utf8))
expect(decoded.itemText == combined.itemText, "Evidence round trip preserves substring geometry and assignments")
let exported = try JSONSerialization.jsonObject(with: Data(combined.evidenceJSON().utf8)) as! [String: Any]
expect(exported["priceLayout"] != nil, "Export includes inspectable column and row-block assignments")

let details = try NuExtractSchema.prompt(vision: basic, part: .details)
let totals = try NuExtractSchema.prompt(vision: basic, part: .amounts)
expect(details.contains("### Text:\n" + basic.itemText), "Actual detail prompt consumes layout hints")
expect(totals.contains("### Text:\n" + basic.text) && !totals.contains("[price-column]"), "Totals continue to consume full unannotated OCR")
let retry = try NuExtractSchema.prompt(vision: basic, part: .details, report: "private computed difference")
expect(retry.contains(basic.itemText) && !retry.contains("private computed difference"), "Retry keeps complete layout evidence without injecting calculated amounts")

// Exercise Vision's actual substring-box API on a generated, nonprivate receipt.
let image = NSImage(size: NSSize(width: 1000, height: 900))
image.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 1000, height: 900).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 32, weight: .regular), .foregroundColor: NSColor.black]
for (i, name) in ["Milk 1.5L", "Bread", "Apples", "Yogurt", "TOTAL"].enumerated() {
    let y = 760 - i * 110
    (name as NSString).draw(at: NSPoint(x: 80, y: y), withAttributes: attributes)
    let amount = i == 4 ? "12.50" : "3.25"
    let width = (amount as NSString).size(withAttributes: attributes).width
    (amount as NSString).draw(at: NSPoint(x: 900 - width, y: Double(y)), withAttributes: attributes)
}
image.unlockFocus()
let vision = try await ReceiptOCR().recognize(image.tiffRepresentation!)
expect(vision.observations.contains { !($0.amountRegions ?? []).isEmpty }, "Real Vision returns exact amount substring boxes")
expect(!vision.priceLayout.columns.isEmpty && vision.priceLayout.columns.last!.anchors.count >= 4, "Generated receipt passes Vision through price-column inference")
checkCoverage(vision)
print("Price layout checks completed.")
