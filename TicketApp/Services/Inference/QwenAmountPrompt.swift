import Foundation

nonisolated enum QwenAmountPrompt {
    static func prompt(vision: OCRScan) throws -> String {
        guard let source = vision.amountText else { throw ReceiptError.missingTotalsAnchor }
        let instructions = """
        Select the checkout summary rows from this receipt OCR excerpt: subtotal, receipt-level taxes, fees or discounts, and final total.
        Pts, Point and Points all mean reward points, not money, regardless of capitalization. Exclude points, points-back offers and rewards balances, including isolated fragments containing only these labels. Never include points as an amount or convert points into money.
        Return only the selected original text rows in their original order. Keep each selected row complete as supplied, including its labels, tax rates, calculation expressions and amounts. Do not rewrite, calculate, correct or invent text. Do not output JSON, Markdown or explanations.
        Exclude product rows, item counts, payment/tender details, transaction/card metadata and unrelated OCR noise. The excerpt may begin or end mid-line; do not reconstruct missing text. If no checkout summary is present, return no text.
        """
        // Qwen3's bundled tokenizer template, single system/user exchange with
        // enable_thinking=false. This stage emits plain text, without JSON grammar.
        return """
        <|im_start|>system
        \(instructions)<|im_end|>
        <|im_start|>user
        \(source)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
    }
}
