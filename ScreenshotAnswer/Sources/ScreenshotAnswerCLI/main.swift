import Foundation
import ScreenshotAnswerCore

@main
enum ScreenshotAnswerCLI {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: screenshot-answer-cli [--ocr-only] <image-path> [lm-studio-model]\n", stderr)
            fputs("       screenshot-answer-cli --text <ocr-text> [lm-studio-model]\n", stderr)
            fputs("       screenshot-answer-cli --describe-text <ocr-text> [lm-studio-model]\n", stderr)
            fputs("       screenshot-answer-cli --describe-image <image-path> [lm-studio-model]\n", stderr)
            fputs("       screenshot-answer-cli --dialogue-text <transcript> [lm-studio-model]\n", stderr)
            exit(EXIT_FAILURE)
        }

        let ocrOnly = CommandLine.arguments[1] == "--ocr-only"
        let textOnly = CommandLine.arguments[1] == "--text"
        let descriptionOnly = CommandLine.arguments[1] == "--describe-text"
        let imageDescriptionOnly = CommandLine.arguments[1] == "--describe-image"
        let dialogueTextOnly = CommandLine.arguments[1] == "--dialogue-text"
        let inputIndex = (
            ocrOnly || textOnly || descriptionOnly || imageDescriptionOnly || dialogueTextOnly
        ) ? 2 : 1
        guard CommandLine.arguments.indices.contains(inputIndex) else {
            fputs("Error: image path or OCR text is required.\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            if ocrOnly {
                let imageURL = URL(fileURLWithPath: CommandLine.arguments[inputIndex])
                print(try await VisionTextRecognizer().recognizeText(in: imageURL))
                return
            }

            let generator = try LMStudioAnswerGenerator()
            let model: String
            let modelIndex = inputIndex + 1
            if CommandLine.arguments.indices.contains(modelIndex) {
                model = CommandLine.arguments[modelIndex]
            } else {
                guard let first = try await generator.availableModels().first else {
                    throw ScreenshotAnswerError.noLMStudioModel
                }
                model = first
            }

            if textOnly || descriptionOnly {
                let text = CommandLine.arguments[inputIndex]
                let generated = if descriptionOnly {
                    try await generator.describe(recognizedText: text, model: model)
                } else {
                    try await generator.answer(recognizedText: text, model: model)
                }
                let offersExplanation = AnswerResponseClassifier
                    .offersContentExplanation(generated)
                let answer = AnswerResponseClassifier.displayText(generated)
                print("[OCR]\n\(text)\n\n[ANSWER]\n\(answer)")
                print("\n[OFFERS_CONTENT_EXPLANATION]\n\(offersExplanation)")
                return
            }

            if imageDescriptionOnly {
                let imageURL = URL(fileURLWithPath: CommandLine.arguments[inputIndex])
                let generated = try await generator.describeImage(
                    imageURL: imageURL,
                    recognizedText: nil,
                    model: model
                )
                print("[IMAGE]\n\(imageURL.path)\n\n[DESCRIPTION]\n\(generated)")
                return
            }

            if dialogueTextOnly {
                let transcript = CommandLine.arguments[inputIndex]
                let generated = try await generator.answerAboutAudio(
                    transcript: transcript,
                    screenshotText: nil,
                    userQuestion: "会話を対話形式で整理し、内容を簡潔に説明してください。",
                    organizeMultipleSpeakers: true,
                    model: model
                )
                print("[TRANSCRIPT]\n\(transcript)\n\n[DIALOGUE ANSWER]\n\(generated)")
                return
            }

            let imageURL = URL(fileURLWithPath: CommandLine.arguments[inputIndex])
            let result = try await ScreenshotAnswerPipeline(generator: generator)
                .process(imageURL: imageURL, model: model)
            print("[OCR]\n\(result.recognizedText)\n\n[ANSWER]\n\(result.answer)")
            print("\n[OFFERS_CONTENT_EXPLANATION]\n\(result.offersContentExplanation)")
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
