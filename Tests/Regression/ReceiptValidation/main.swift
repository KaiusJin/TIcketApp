import Foundation

func expect(_ value: Bool, _ label: String) {
    precondition(value, "FAIL: \(label)")
    print("PASS: \(label)")
}
func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
func output(_ object: [String: Any]) throws -> ModelOutput { .init(text: try json(object), reachedLimit: false) }
let items: [[String: Any]] = [["name": "Wings", "total_price": "25.99"], ["name": "Sangria", "total_price": "9.39"], ["name": "Beer", "total_price": "8.79"]]
let details: [String: Any] = ["merchant": "Example", "items": items]
let totals: [String: Any] = ["subtotal": "44.17", "total": "49.91", "tax": "5.74"]
var receipt = details
receipt["totals"] = totals
receipt["date"] = "2026-11-11"
let validJSON = try json(receipt)
expect(ReceiptValidation.check(validJSON).passed, "Flat totals plus item subtotal pass")
expect(ReceiptValidation.totalsReport(totals) == nil, "Subtotal + tax equals total")
expect(ReceiptValidation.itemsReport(items, totals: totals) == nil, "Items may equal subtotal")
let totalInclusiveItems: [[String: Any]] = [["name": "Tax inclusive purchase", "total_price": "49.91"]]
expect(ReceiptValidation.itemsReport(totalInclusiveItems, totals: totals) == nil, "Items may equal total even when unequal to subtotal")
expect(ReceiptValidation.itemsReport([["name": "Missing lines", "total_price": "40.00"]], totals: totals) != nil, "Items unequal to both targets require manual review")
let extras: [String: Any] = ["subtotal": "10.00", "total": "15.00", "tax": "1.00", "tax_2": "2.00", "tip": "1.00", "processing_fee": "2.00", "discount": "-2.00", "other_item_1": "1.00"]
expect(ReceiptValidation.totalsReport(extras) == nil, "Every additional entry counted once, including negative discounts")
expect(ReceiptValidation.totalsReport(["subtotal": "10", "total": "10.01"]) != nil, "Decimal equality is exact, including one-cent differences")
for single: [String: Any] in [["total": "49.91"], ["subtotal": "49.91"], ["subtotal": NSNull(), "total": "49.91"], ["subtotal": "49.91", "total": NSNull()]] {
    let normalized = ReceiptValidation.normalizedTotals(single)
    expect(normalized["subtotal"] as? String == "49.91" && normalized["total"] as? String == "49.91", "Single existing total copied verbatim to missing peer")
    expect(ReceiptValidation.totalsReport(single) == nil, "Single amount without charges balances after fallback")
}
expect(ReceiptValidation.totalsReport([:]) != nil, "Both missing triggers first-step retry")
expect(ReceiptValidation.totalsReport(["subtotal": NSNull(), "total": NSNull()]) != nil, "Both null triggers first-step retry")
expect(ReceiptValidation.totalsReport(["total": "49.91", "tax": "5.74"]) != nil, "Fallback precedes totals equation; tax is not subtracted to invent subtotal")
expect(ReceiptValidation.totalsReport(["subtotal": "10", "total": "10", "tax": NSNull()]) != nil, "Unreadable charge is not silently treated as zero")
expect(ReceiptValidation.itemsReport([["name": "Unreadable", "total_price": NSNull()]], totals: totals) != nil, "Unknown item amount requests detail recheck")
expect(ReceiptValidation.itemsReport(items, totals: [:]) == nil, "No second-step numerical retry without either target")
for key in ["quantity", "unit", "unit_price", "discounts"] {
    var invalid = receipt
    var badItems = items
    badItems[0][key] = "1"
    invalid["items"] = badItems
    expect(!ReceiptValidation.check(try json(invalid)).passed, "Removed item field rejected: \(key)")
}
var legacy = receipt
legacy["adjustments"] = []
expect(!ReceiptValidation.check(try json(legacy)).passed, "Old adjustments array rejected")
for key in ["grand_total", "tax_total", "other_item_0", "arbitrary_field"] {
    var invalid = receipt
    var badTotals = totals
    badTotals[key] = "1"
    invalid["totals"] = badTotals
    expect(!ReceiptValidation.check(try json(invalid)).passed, "Unbalanced additional amount flagged: \(key)")
}
expect(!ReceiptValidation.check("{\"items\":").passed, "Truncated JSON rejected")
expect(!ReceiptValidation.check(validJSON + "garbage").passed, "Trailing garbage rejected")
expect(ReceiptValidation.check("```json\n" + validJSON + "\n```").passed, "Fenced manual JSON accepted")
let duplicate = validJSON.replacingOccurrences(of: "\"total\":\"49.91\"", with: "\"total\":\"49.91\",\"total\":\"49.91\"")
expect(ReceiptValidation.check(duplicate).formattedJSON == nil, "Duplicate amounts preserved as raw output, not collapsed")
let escapedDuplicate = validJSON.replacingOccurrences(of: "\"total\":\"49.91\"", with: "\"total\":\"49.91\",\"to\\u0074al\":\"49.91\"")
expect(!ReceiptValidation.check(escapedDuplicate).passed, "Escaped duplicate field rejected")

func scan(_ text: String) -> OCRScan {
    OCRScan(observations: [OCRLine(candidates: [.init(text: text, confidence: 0.9)], x: 0.1, y: 0.5, width: 0.4, height: 0.02)])
}
let evidence = scan("Example 2026-11-11 Total 49.91")
let dateOutput = ModelOutput(text: "2026-11-11", reachedLimit: false)
let checkout = "Subtotal 44.17\nTax 5.74\nTotal 49.91"
let amountsPrompt = try NuExtractSchema.amountPrompt(text: checkout)
expect(amountsPrompt.contains(checkout), "NuExtract receives Qwen checkout output")
let detailsPrompt = try ReceiptSchema.extractionPrompt(vision: evidence, part: .details)
expect(detailsPrompt.contains(evidence.itemText), "Details retain full OCR item evidence")
let amountsShape = try ReceiptSchema.schema(for: .amounts).promptShape()
let detailsShape = try ReceiptSchema.schema(for: .details).promptShape()
expect(!amountsShape.contains("items") && !detailsShape.contains("totals") && !detailsShape.contains("date"), "Stage schemas remain disjoint from date extraction")
let detailsGrammar = try NuExtractSchema.grammar(for: .details)
expect(!detailsPrompt.contains("receipt_type") && !detailsGrammar.contains("receipt-kind"), "Type removed from extraction prompt and grammar")
let merged = try ReceiptSchema.merge(amounts: output(["totals": ["subtotal": NSNull(), "total": "49.91"]]), details: output(details), date: dateOutput)
let mergedObject = try JSONSerialization.jsonObject(with: Data(merged.text.utf8)) as! [String: Any]
expect((mergedObject["totals"] as! [String: Any])["subtotal"] as? String == "49.91", "Final merged JSON applies missing-total fallback")
expect(mergedObject["date"] as? String == "2026-11-11" && mergedObject["receipt_type"] == nil, "Date merged at root and type absent")

let header = String(repeating: "头", count: 40) + "2026-11-11"
let footer = "2026-11-11" + String(repeating: "🧾", count: 40)
let completeOCR = header + "MIDDLE DATE 2000-01-01" + footer
let datePrompt = QwenDateExtraction.prompt(vision: scan(completeOCR))
expect(datePrompt.contains(completeOCR), "Date input preserves the complete OCR including the middle")
for short in ["", "2026-11-11", String(repeating: "a", count: 75)] {
    let prompt = QwenDateExtraction.prompt(vision: scan(short))
    expect(prompt.contains("<|im_start|>user\n" + short + "<|im_end|>"), "Short OCR is passed unchanged and only once")
}
for valid in ["2026-11-11", "2024-02-29", "2000-02-29", "2026-12-31"] {
    expect(QwenDateExtraction.date(from: .init(text: " \n" + valid + "\n", reachedLimit: false)) == valid, "Valid Gregorian date accepted: \(valid)")
}
for invalid in ["null", "", "2026-2-03", "2026-02-29", "1900-02-29", "0000-01-01", "2026-13-01", "2026-04-31", "2026-01-00", "2026-11-11 extra", "```2026-11-11```"] {
    expect(QwenDateExtraction.date(from: .init(text: invalid, reachedLimit: false)) == nil, "Invalid or unknown date remains null: \(invalid)")
}
expect(QwenDateExtraction.date(from: .init(text: "2026-11-11", reachedLimit: true)) == nil, "Truncated dates are not accepted")
var invalidDate = receipt
invalidDate["date"] = "2026-02-29"
expect(!ReceiptValidation.check(try json(invalidDate)).passed, "Manual JSON validates actual calendar dates")
var legacyType = receipt
legacyType["receipt_type"] = "restaurant"
expect(!ReceiptValidation.check(try json(legacyType)).passed, "Removed receipt_type rejected")

// NuExtract requires both keys even when their values are unknown.
func amountOutput(_ values: [String: Any]) throws -> ModelOutput {
    var values = values
    if values["subtotal"] == nil { values["subtotal"] = NSNull() }
    if values["total"] == nil { values["total"] = NSNull() }
    return try output(["totals": values])
}

@MainActor func route(initialTotals: [String: Any], firstItems: [[String: Any]], fixedTotals: [String: Any]? = nil,
                      expectedRetries: [ReceiptExtractionPart], expectedPass: Bool, date: ModelOutput = dateOutput) async throws {
    var calls: [ReceiptExtractionPart] = []
    var retries: [ReceiptExtractionPart] = []
    var stages: [ReceiptStage] = []
    var partials: [ReceiptExtractionPart] = []
    var loads: [ReceiptModelKind] = []
    var dateCalls = 0
    var datePreserved = false
    var firstDetails = details
    firstDetails["items"] = firstItems
    let result = try await ReceiptPipeline.run(vision: { evidence }, load: { loads.append($0) },
        parseDate: { scan in
            dateCalls += 1
            expect(scan.text == evidence.text, "Date stage receives Vision evidence")
            return date
        }, prepareAmounts: { _ in .init(text: checkout, reachedLimit: false) },
        parseAmounts: { text in
            calls.append(.amounts)
            expect(text == checkout, "Amounts consume Qwen checkout text")
            return try amountOutput(initialTotals)
        }, parse: { scan, part in
            calls.append(part)
            expect(scan.text == evidence.text, "Original OCR retained across both steps")
            if part == .details, expectedRetries.contains(.amounts) { expect(retries == [.amounts], "Amount retry finishes before detail generation") }
            return try output(firstDetails)
        }, retryAmounts: { text, report in
            retries.append(.amounts)
            expect(text == checkout && report.contains("Validation results:"), "Retry reuses checkout text and receives diagnostic")
            return try amountOutput(fixedTotals ?? initialTotals)
        }, emit: { event in
            if case .date(let output) = event { datePreserved = output.text == date.text }
            if case .stage(let stage) = event { stages.append(stage) }
            if case .partial(let part, _) = event { partials.append(part) }
        })
    expect(calls == [.amounts, .details] && loads == [.amounts, .amounts, .text, .text], "Totals and items each use their designated model")
    expect(dateCalls == 1 && datePreserved, "Date generated once and raw output preserved")
    expect(retries == expectedRetries, "Only totals can retry, at most once")
    expect(result.passed == expectedPass, "Final acceptance reflects both equations")
    expect(partials.count == 2 + expectedRetries.count, "All original and retry outputs retained")
    var expectedStages: [ReceiptStage] = [.visionOCR, .dateParse, .settlementText, .initialParse]
    if expectedRetries.contains(.amounts) { expectedStages.append(.amountRetry) }
    expectedStages.append(.detailParse)
    expect(stages == expectedStages, "Visible stages contain no item correction")
}
try await route(initialTotals: totals, firstItems: items, expectedRetries: [], expectedPass: true)
try await route(initialTotals: totals, firstItems: totalInclusiveItems, expectedRetries: [], expectedPass: true)
try await route(initialTotals: ["total": "49.91"], firstItems: totalInclusiveItems, expectedRetries: [], expectedPass: true)
try await route(initialTotals: ["subtotal": "49.91"], firstItems: totalInclusiveItems, expectedRetries: [], expectedPass: true)
try await route(initialTotals: [:], firstItems: items, fixedTotals: totals, expectedRetries: [.amounts], expectedPass: true)
try await route(initialTotals: ["subtotal": NSNull(), "total": NSNull()], firstItems: items, expectedRetries: [.amounts], expectedPass: false)
try await route(initialTotals: ["subtotal": "44.17", "tax": "4.00", "total": "49.91"], firstItems: items, fixedTotals: totals, expectedRetries: [.amounts], expectedPass: true)
try await route(initialTotals: ["total": "49.91", "tax": "5.74"], firstItems: items, fixedTotals: totals, expectedRetries: [.amounts], expectedPass: true)
let missingItems = Array(items.prefix(2))
try await route(initialTotals: totals, firstItems: missingItems, expectedRetries: [], expectedPass: false)
try await route(initialTotals: [:], firstItems: missingItems, fixedTotals: totals, expectedRetries: [.amounts], expectedPass: false)
try await route(initialTotals: ["subtotal": "44.17", "total": "50", "tax": "5.74"], firstItems: missingItems, expectedRetries: [.amounts], expectedPass: false)

for unknown in [ModelOutput(text: "null", reachedLimit: false), ModelOutput(text: "2026-02-29", reachedLimit: false), ModelOutput(text: "2026-11-11", reachedLimit: true)] {
    try await route(initialTotals: totals, firstItems: items, expectedRetries: [], expectedPass: false, date: unknown)
}

for bad in [ModelOutput(text: "{", reachedLimit: false), ModelOutput(text: "{}", reachedLimit: true), ModelOutput(text: "{}", reachedLimit: false, repetitionDetected: true), try output(details)] {
    var calls = 0
    var preserved = false
    do {
        _ = try await ReceiptPipeline.run(vision: { evidence }, load: { _ in },
            parseDate: { _ in dateOutput }, prepareAmounts: { _ in .init(text: checkout, reachedLimit: false) },
            parseAmounts: { _ in calls += 1; return bad }, parse: { _, _ in fatalError("Invalid totals must stop before items") },
            retryAmounts: { _, _ in fatalError("Invalid partial should not undergo arithmetic") }, emit: { if case .partial = $0 { preserved = true } })
        fatalError("Invalid partial accepted")
    } catch { expect(calls == 1 && preserved, "Invalid or truncated amounts stop safely with raw evidence") }
}
var cancellationCalls = 0
do {
    _ = try await ReceiptPipeline.run(vision: { evidence }, load: { _ in },
        parseDate: { _ in cancellationCalls += 1; throw CancellationError() },
        prepareAmounts: { _ in fatalError("Cancelled date continued") }, parseAmounts: { _ in fatalError("Cancelled date continued") },
        parse: { _, _ in fatalError("Cancelled date continued") },
        retryAmounts: { _, _ in fatalError("Cancelled generation retried") }, emit: { _ in })
    fatalError("Cancellation swallowed")
} catch is CancellationError { expect(cancellationCalls == 1, "Cancellation does not retry") }
let repeatedItem = #"{"name":"POTATO","total_price":"4.48"}"#
var monitor = ReceiptOutputMonitor()
let prefix = "{\"items\":[" + Array(repeating: repeatedItem, count: 3).joined(separator: ",")
for character in prefix { monitor.append(String(character)) }
expect(!monitor.shouldStop, "Three repeated purchase lines are preserved")
for character in "," + repeatedItem { monitor.append(String(character)) }
expect(monitor.shouldStop && monitor.repeatedItemRun == 4, "Four identical streamed item objects trigger review across character-sized chunks")
var resetMonitor = ReceiptOutputMonitor()
resetMonitor.append(prefix + "," + repeatedItem.replacingOccurrences(of: "POTATO", with: "ONION") + "," + repeatedItem)
expect(!resetMonitor.shouldStop && resetMonitor.repeatedItemRun == 1, "Different item resets consecutive repetition detection")
var nestedMonitor = ReceiptOutputMonitor()
nestedMonitor.append("{\"adjustments\":[" + Array(repeating: repeatedItem, count: 5).joined(separator: ",") + "]}")
expect(!nestedMonitor.shouldStop, "Only the root items array is monitored")
var escapedMonitor = ReceiptOutputMonitor()
let escapedItem = repeatedItem.replacingOccurrences(of: "POTATO", with: #"[ } \"POTATO\" ]"#)
escapedMonitor.append("{\"items\":[" + Array(repeating: escapedItem, count: 4).joined(separator: ","))
expect(escapedMonitor.shouldStop, "Brackets and escaped quotes inside item names do not corrupt monitoring")
