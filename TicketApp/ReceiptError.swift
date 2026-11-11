import Foundation

nonisolated enum ReceiptError: LocalizedError {
    case invalidImage, inputTooLong, invalidModelInput, guidedGenerationFailed
    case missingTextModel, modelLoadFailed, modelDecodeFailed, modelBusy
    case invalidExtractionShape, missingTotalsAnchor, invalidSettlementText

    var errorDescription: String? {
        switch self {
        case .missingTextModel: "A required local model is missing or not loaded. Include the Qwen3-0.6B and NuExtract GGUF resources and rebuild."
        case .modelLoadFailed: "Unable to initialize the local model. Close other apps and try again, or verify the GGUF model file."
        case .missingTotalsAnchor: "No total or subtotal label was found in the OCR."
        case .invalidSettlementText: "Checkout text is empty, incomplete or unavailable."
        case .modelDecodeFailed: "Local model inference failed. OCR evidence and any available preview are preserved; please try again."
        case .modelBusy: "The local model is still running. Wait for it to finish or cancel before retrying."
        case .invalidExtractionShape: "The model returned an unexpected receipt structure."
        case .guidedGenerationFailed: "Structured extraction could not be completed."
        case .inputTooLong: "The receipt exceeds the local model context budget. OCR evidence is preserved. Split the receipt into smaller sections and try again."
        case .invalidImage: "Unable to read this image. Please select another photo."
        case .invalidModelInput: "Unable to tokenize the receipt for the local model. Verify the GGUF model file and retry."
        }
    }
}
