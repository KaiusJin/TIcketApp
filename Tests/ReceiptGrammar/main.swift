import Foundation
import MLXLMCommon
import MLXGuidedGeneration

// No model or receipt image is loaded. Use printable ASCII so token-mask decisions are inspectable.
struct ASCIITokenizer: Tokenizer {
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }
    func convertTokenToId(_ token: String) -> Int? {
        if token == eosToken { return 95 }
        guard token.unicodeScalars.count == 1, let scalar = token.unicodeScalars.first,
              (32...126).contains(scalar.value) else { return nil }
        return Int(scalar.value) - 32
    }
    func convertIdToToken(_ id: Int) -> String? {
        if id == 95 { return eosToken }
        guard (0..<95).contains(id) else { return nil }
        return String(UnicodeScalar(id + 32)!)
    }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.map { convertTokenToId(String($0))! } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.compactMap(convertIdToToken).joined() }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}

let tokenizer = ASCIITokenizer()
let schema = try ReceiptSchema.constraintJSON()
func expect(_ value: Bool, _ label: String) {
    precondition(value, "FAIL: \(label)")
    print("PASS: \(label)")
}
func processor(schemaText: String = schema) throws -> GrammarConstraint {
    let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
    let grammarTokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: 95)
    return try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schemaText, fastForward: false)
}
func allows(_ id: Int, mask: MaskResult) -> Bool {
    !mask.needsApply || (UInt32(bitPattern: mask.mask[id / 32]) & (UInt32(1) << UInt32(id % 32))) != 0
}
func feed(_ text: String, to grammar: GrammarConstraint) throws -> Bool {
    for id in tokenizer.encode(text: text, addSpecialTokens: false) {
        if try !allows(id, mask: grammar.computeMask()) { return false }
        let result = try grammar.commitToken(Int32(id))
        precondition(result.tokens.isEmpty, "Fast-forward must be disabled")
    }
    return true
}
func accepts(_ text: String, schemaText: String = schema) throws -> Bool {
    let grammar = try processor(schemaText: schemaText)
    guard try feed(text, to: grammar), try allows(95, mask: grammar.computeMask()) else { return false }
    return try grammar.commitToken(95).isTerminated
}
let receipt = #"{"receipt_type":"restaurant","merchant":"Cafe","items":[{"name":"Noodles","total_price":"29.98"}],"totals":{"subtotal":"29.98","total":"26.98","discount":"-3.00"}}"#
expect(try accepts(receipt), "Complete simplified receipt matches compiled XGrammar schema")
let itemsStart = receipt.range(of: "\"items\":[")!.upperBound
let itemsEnd = receipt.range(of: "],\"totals\"")!.lowerBound
let repeated = String(receipt[..<itemsStart]) + Array(repeating: String(receipt[itemsStart..<itemsEnd]), count: 4).joined(separator: ",") + String(receipt[itemsEnd...])
expect(try accepts(repeated), "Schema alone allows repeated purchase lines; semantic repetition checks must be separate")
expect(try accepts(receipt.replacingOccurrences(of: "\"26.98\"", with: "null")), "Unknown monetary null remains expressible")
expect(try !accepts(receipt.replacingOccurrences(of: "\"26.98\"", with: "26.98")), "Numeric money tokens blocked")
expect(try !accepts(receipt.replacingOccurrences(of: "\"26.98\"", with: "\"CAD26.98\"")), "Non-decimal monetary strings blocked")
expect(try !accepts(receipt.replacingOccurrences(of: "\"restaurant\"", with: "\"invalid\"")), "Invalid enum blocked")
expect(try !accepts(receipt.replacingOccurrences(of: "\"merchant\":\"Cafe\",", with: "")), "Missing required field blocked")
expect(try !accepts(receipt.replacingOccurrences(of: "\"receipt_type\":", with: "\"payment\":null,\"receipt_type\":")), "Removed payment field blocked")
expect(try !accepts(receipt.replacingOccurrences(of: "\"merchant\":\"Cafe\",", with: "\"merchant\":\"Cafe\",\"merchant\":\"Cafe\",")), "Repeated key blocked")
expect(try !accepts(receipt.replacingOccurrences(of: "\"name\":", with: "\"modifiers\":[],\"name\":")), "Removed modifiers field blocked during generation")
expect(try !accepts(receipt + " extra"), "Text after JSON blocked")
let initial = try processor()
expect(try !allows(95, mask: initial.computeMask()), "EOS blocked before JSON completion")
expect(try feed("{", to: initial), "Valid prefix accepted")
let clone = try processor()
expect(try feed("{", to: clone), "Fresh matcher replays prefix independently")
expect(try feed(String(receipt.dropFirst()), to: initial), "Original matcher completes")
expect(try feed(String(receipt.dropFirst()), to: clone), "Copied matcher advances independently")
let adapter = try ReceiptGrammarProcessor(tokenizer: tokenizer, eos: 95, schema: schema)
expect(!adapter.copy().failed, "Processor copies work without unsupported XGrammar Fork")
let failed = try processor()
do {
    _ = try failed.commitToken(Int32(tokenizer.convertTokenToId("]")!))
    fatalError("Invalid token was accepted")
} catch GrammarError.commitFailed { print("PASS: Invalid token commit reports an error") }
print("All guided-generation grammar checks passed.")

// Optional smoke check against the downloaded Qwen vocabulary, without loading its weights.
if CommandLine.arguments.count > 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))) as! [String: Any]
    var ids = (object["model"] as! [String: Any])["vocab"] as! [String: Int]
    for token in object["added_tokens"] as! [[String: Any]] { ids[token["content"] as! String] = token["id"] as? Int }
    var pieces = [String](repeating: "", count: ids.values.max()! + 1)
    for (piece, id) in ids { pieces[id] = piece }
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as! [String: Any]
    let textConfig = config["text_config"] as? [String: Any]
    let configEOS = (config["eos_token_id"] ?? textConfig?["eos_token_id"]) as! Int
    let tokenizerConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))) as! [String: Any]
    let eos = (tokenizerConfig["eos_token"] as? String).flatMap { ids[$0] } ?? configEOS
    let actualTokenizer = try GrammarTokenizer(vocab: pieces, vocabType: .byteLevel, eosTokenId: Int32(eos))
    let actual = try GrammarConstraint(tokenizer: actualTokenizer, jsonSchema: schema, fastForward: false)
    expect(try !allows(eos, mask: actual.computeMask()), "Qwen EOS blocked before receipt is complete")
    for character in receipt {
        let id = ids[String(character)]!
        let allowed = try allows(id, mask: actual.computeMask())
        precondition(allowed, "Valid receipt token rejected by Qwen grammar")
        _ = try actual.commitToken(Int32(id))
    }
    expect(try allows(eos, mask: actual.computeMask()), "Qwen EOS allowed only after completed receipt")
    expect(try actual.commitToken(Int32(eos)).isTerminated, "Downloaded Qwen vocabulary accepts complete receipt schema")
    let partial = try GrammarConstraint(tokenizer: actualTokenizer, jsonSchema: schema, fastForward: false)
    for character in "{\"receipt_type\":\"restaurant\",\"merchant\":\"" {
        _ = try partial.commitToken(Int32(ids[String(character)]!))
    }
    let (partialMask, _) = ReceiptGrammarProcessor.tokenMask(try partial.computeMask(), vocabSize: pieces.count, logitCount: pieces.count + 32, excluding: Set([configEOS]).subtracting([eos]))
    expect(!partialMask[eos] && !partialMask[configEOS], "Config and chat EOS cannot terminate an incomplete string")
    expect(partialMask.suffix(32).allSatisfy { !$0 }, "Model padding remains masked with alternate stop IDs")
}

let amountSchema = try ReceiptSchema.schema(for: .amounts).constraintJSON()
expect(try accepts(#"{"totals":{"subtotal":"44.17","total":"49.91","tax":"5.74"}}"#, schemaText: amountSchema), "First-stage grammar supports flat optional totals")
expect(try accepts(#"{"totals":{"tax":"1.00","tax_2":"2.00","other_item_1":"3.00","processing_fee":"0.50","discount":"-1.00","total":"15.50","subtotal":"10.00"}}"#, schemaText: amountSchema), "Dynamic fee names and repeated tax entries accepted in any order")
expect(try accepts(#"{"totals":{}}"#, schemaText: amountSchema), "Absent totals can be represented and retried by application")
expect(try accepts(#"{"totals":{"total":null}}"#, schemaText: amountSchema), "Unknown total can be represented")
expect(try !accepts(#"{"totals":{"garbage":"1.00"}}"#, schemaText: amountSchema), "Unknown monetary key blocked")
expect(try !accepts(#"{"totals":{"other_item_0":"1.00"}}"#, schemaText: amountSchema), "Invalid numbered key blocked")
expect(try !accepts(#"{"totals":{"total":15.50}}"#, schemaText: amountSchema), "Numeric amount blocked in flat totals")
expect(try !accepts(#"{"totals":{"total":"15.50"},"adjustments":[]}"#, schemaText: amountSchema), "Legacy adjustments array blocked")
