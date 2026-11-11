import Foundation

nonisolated enum ReceiptError: LocalizedError {
    case invalidImage, inputTooLong, invalidModelInput, guidedGenerationFailed
    case missingTextModel, modelLoadFailed, modelDecodeFailed, modelBusy
    case invalidExtractionShape

    var errorDescription: String? {
        switch self {
        case .missingTextModel: "The bundled NuExtract model is missing. Add NuExtract-1.5-smol-Q4_K_M.gguf to the app resources and rebuild."
        case .modelLoadFailed: "Unable to initialize the local NuExtract model. Close other apps and try again, or verify the GGUF model file."
        case .modelDecodeFailed: "Local model inference failed. OCR evidence and any available preview are preserved; please try again."
        case .modelBusy: "The local model is still running. Wait for it to finish or cancel before retrying."
        case .invalidExtractionShape: "The model returned an unexpected receipt structure. The raw output is preserved for review."
        case .guidedGenerationFailed: "Structured extraction could not be completed. Any available preview and OCR evidence are preserved; retry or review manually."
        case .inputTooLong: "The receipt exceeds the local model context budget. OCR evidence is preserved. Split the receipt into smaller sections and try again."
        case .invalidImage: "Unable to read this image. Please select another photo."
        case .invalidModelInput: "Unable to tokenize the receipt for NuExtract. Verify the GGUF model file and retry."
        }
    }
}
